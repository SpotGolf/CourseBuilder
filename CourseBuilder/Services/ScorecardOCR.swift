import AppKit
import Vision

enum ScorecardOCR {

    struct TextBlock {
        let text: String
        let boundingBox: CGRect // normalized, origin at bottom-left
    }

    enum OCRError: LocalizedError {
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "Could not convert image to CGImage for OCR processing"
            }
        }
    }

    // MARK: - Text Extraction

    /// Extract all text blocks from an image, sorted top-to-bottom then left-to-right.
    /// Scales the image up before OCR to improve detection of small digits.
    static func extractText(from image: NSImage) throws -> [TextBlock] {
        guard let scaledCGImage = scaleUp(image, targetMinDimension: 3000) else {
            throw OCRError.invalidImage
        }

        let handler = VNImageRequestHandler(cgImage: scaledCGImage, options: [:])

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = ["Par", "Handicap", "Hdcp", "Out", "In", "Tot", "Slope", "Rating"]

        try handler.perform([request])

        guard let observations = request.results else {
            return []
        }

        let blocks = observations.compactMap { observation -> TextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextBlock(text: candidate.string, boundingBox: observation.boundingBox)
        }

        // Sort top-to-bottom (descending midY since Vision uses bottom-left origin),
        // then left-to-right (ascending minX).
        // Use a tolerance of ~0.02 for "same row" detection.
        let rowTolerance: CGFloat = 0.02
        let sorted = blocks.sorted { a, b in
            let aMidY = a.boundingBox.midY
            let bMidY = b.boundingBox.midY
            if abs(aMidY - bMidY) > rowTolerance {
                return aMidY > bMidY // higher Y = higher on page = comes first
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        return sorted
    }

    // MARK: - Scorecard Parsing

    private static let summaryLabels: Set<String> = ["out", "in", "total", "tot"]

    /// Attempt to parse extracted text blocks into scorecard data.
    /// This is a best-effort parser -- OCR output is noisy and real scorecards vary widely.
    static func parseScorecard(from image: NSImage) throws -> ScorecardData {
        let blocks = try extractText(from: image)
        return parseScorecardData(from: blocks)
    }

    /// Parse scorecard data from pre-extracted text blocks.
    /// Separated from `parseScorecard` to allow unit testing without images.
    static func parseScorecardData(from blocks: [TextBlock]) -> ScorecardData {
        let rows = groupIntoRows(blocks)
        return classifyRows(rows)
    }

    /// Classifies grouped rows into par, handicap, and tee data, then builds holes.
    private static func classifyRows(_ rows: [[TextBlock]]) -> ScorecardData {
        var parValues: [Int] = []
        var maleHandicapValues: [Int] = []
        var femaleHandicapValues: [Int] = []
        var teeRows: [(name: String, yardages: [Int])] = []

        for row in rows {
            guard !row.isEmpty else { continue }

            let label = row[0].text
            let normalizedLabel = label.lowercased()
            // Skip header rows (e.g. "Hole 1 2 3 ..." or "Hole1")
            if normalizedLabel.hasPrefix("hole") { continue }

            let remaining = Array(row.dropFirst())
            // Split merged text blocks (e.g. "458 335") and trim leading/trailing
            // non-numeric characters (e.g. "| 306") before parsing.
            // Filter out "Out"/"In"/"Total" summary labels.
            let numbers = remaining
                .flatMap { $0.text.split(separator: " ") }
                .filter { !summaryLabels.contains($0.lowercased()) }
                .compactMap { token -> Int? in
                    let trimmed = token.trimmingCharacters(in: .decimalDigits.inverted)
                    return Int(trimmed)
                }

            if normalizedLabel.contains("par") && !normalizedLabel.contains("handicap") {
                // Use the first par row found (typically men's par)
                if parValues.isEmpty {
                    parValues = numbers.filter { $0 >= 2 && $0 <= 6 }
                }
            } else if normalizedLabel.contains("handicap") || normalizedLabel.contains("hdcp") {
                let filtered = numbers.filter { $0 >= 1 && $0 <= 18 }
                if normalizedLabel.contains("women") || normalizedLabel.contains("female") || normalizedLabel.contains("lad") {
                    if femaleHandicapValues.isEmpty {
                        femaleHandicapValues = filtered
                    }
                } else {
                    if maleHandicapValues.isEmpty {
                        maleHandicapValues = filtered
                    }
                }
            } else if numbers.count >= 3 {
                // Likely a tee name row with yardages — filter out totals (values > 1000)
                let holeYardages = numbers.filter { $0 < 1000 }
                teeRows.append((name: label, yardages: holeYardages))
            }
        }

        // Determine hole count from whichever data we found
        let holeCount = max(
            parValues.count,
            maleHandicapValues.count,
            femaleHandicapValues.count,
            teeRows.first?.yardages.count ?? 0
        )

        guard holeCount > 0 else {
            return ScorecardData(holes: [], teeNames: [])
        }

        var holes: [Hole] = []
        for i in 0..<holeCount {
            let par = i < parValues.count ? parValues[i] : 0
            let handicap = i < maleHandicapValues.count ? maleHandicapValues[i] : 0
            let femaleHandicap = i < femaleHandicapValues.count ? femaleHandicapValues[i] : 0

            var yardages: [String: Int] = [:]
            for tee in teeRows {
                if i < tee.yardages.count {
                    yardages[tee.name] = tee.yardages[i]
                }
            }

            let hole = Hole(
                number: i + 1,
                par: par,
                maleHandicap: handicap,
                femaleHandicap: femaleHandicap,
                yardages: yardages
            )
            holes.append(hole)
        }

        let teeNames = teeRows.map { $0.name }
        return ScorecardData(holes: holes, teeNames: teeNames)
    }

    // MARK: - Private Helpers

    /// Scales an NSImage up so its smallest dimension reaches `targetMinDimension` pixels.
    /// Uses actual pixel dimensions rather than point size to handle Retina images correctly.
    /// Returns nil if the image has no representations.
    private static func scaleUp(_ image: NSImage, targetMinDimension: CGFloat) -> CGImage? {
        guard let rep = image.representations.first else { return nil }
        let pixelWidth = rep.pixelsWide
        let pixelHeight = rep.pixelsHigh
        let currentMin = CGFloat(min(pixelWidth, pixelHeight))
        let factor = currentMin < targetMinDimension ? targetMinDimension / currentMin : 1.0

        let newWidth = Int(CGFloat(pixelWidth) * factor)
        let newHeight = Int(CGFloat(pixelHeight) * factor)
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: newWidth,
            pixelsHigh: newHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight))
        NSGraphicsContext.restoreGraphicsState()
        return bitmapRep.cgImage
    }

    /// Groups text blocks into rows based on Y position proximity.
    static func groupIntoRows(_ blocks: [TextBlock]) -> [[TextBlock]] {
        guard !blocks.isEmpty else { return [] }

        let rowTolerance: CGFloat = 0.02
        var rows: [[TextBlock]] = []
        var currentRow: [TextBlock] = [blocks[0]]
        var currentMidY = blocks[0].boundingBox.midY

        for block in blocks.dropFirst() {
            let midY = block.boundingBox.midY
            if abs(midY - currentMidY) <= rowTolerance {
                currentRow.append(block)
            } else {
                rows.append(currentRow)
                currentRow = [block]
                currentMidY = midY
            }
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }
}

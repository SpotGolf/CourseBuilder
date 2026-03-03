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
    static func extractText(from image: NSImage) throws -> [TextBlock] {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw OCRError.invalidImage
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
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

    /// Attempt to parse extracted text blocks into scorecard data.
    /// This is a best-effort parser -- OCR output is noisy and real scorecards vary widely.
    static func parseScorecard(from image: NSImage) throws -> ScorecardData {
        let blocks = try extractText(from: image)

        let rows = groupIntoRows(blocks)

        var parValues: [Int] = []
        var handicapValues: [Int] = []
        var teeRows: [(name: String, yardages: [Int])] = []

        for row in rows {
            guard !row.isEmpty else { continue }

            let label = row[0].text
            let normalizedLabel = label.lowercased()
            let remaining = Array(row.dropFirst())
            let numbers = remaining.compactMap { Int($0.text) }

            if normalizedLabel.contains("par") {
                parValues = numbers
            } else if normalizedLabel.contains("handicap") || normalizedLabel.contains("hdcp") {
                handicapValues = numbers
            } else if numbers.count >= 3 {
                // Likely a tee name row with yardages
                teeRows.append((name: label, yardages: numbers))
            }
        }

        // Determine hole count from whichever data we found
        let holeCount = max(
            parValues.count,
            handicapValues.count,
            teeRows.first?.yardages.count ?? 0
        )

        guard holeCount > 0 else {
            return ScorecardData(holes: [], teeNames: [])
        }

        var holes: [Hole] = []
        for i in 0..<holeCount {
            let par = i < parValues.count ? parValues[i] : 0
            let handicap = i < handicapValues.count ? handicapValues[i] : 0

            var yardages: [String: Int] = [:]
            for tee in teeRows {
                if i < tee.yardages.count {
                    yardages[tee.name] = tee.yardages[i]
                }
            }

            let hole = Hole(
                number: i + 1,
                par: par,
                handicap: handicap,
                yardages: yardages
            )
            holes.append(hole)
        }

        let teeNames = teeRows.map { $0.name }
        return ScorecardData(holes: holes, teeNames: teeNames)
    }

    // MARK: - Private Helpers

    /// Groups text blocks into rows based on Y position proximity.
    private static func groupIntoRows(_ blocks: [TextBlock]) -> [[TextBlock]] {
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

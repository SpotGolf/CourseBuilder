import Foundation

struct ScorecardData {
    var holes: [Hole]
    var teeNames: [String]
}

enum ScraperError: LocalizedError {
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return "Scraper error: \(msg)"
        }
    }
}

enum ScorecardScraper {

    /// Parses GolfLink-style HTML scorecard tables using XMLDocument.
    static func parseGolfLink(html: String) throws -> ScorecardData {
        let doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML])

        guard let root = doc.rootElement() else {
            throw ScraperError.parseError("No root element found")
        }

        let tables = try root.nodes(forXPath: "//table")
        guard let tableNode = tables.first, let table = tableNode as? XMLElement else {
            throw ScraperError.parseError("No <table> element found")
        }

        let rows = table.elements(forName: "tr")
        guard !rows.isEmpty else {
            throw ScraperError.parseError("No rows found in table")
        }

        // First row = headers with hole numbers
        let headerCells = cellTexts(from: rows[0])
        // Build a mapping of column index -> hole number (skip non-numeric headers like "", "Out", "In", "Tot")
        var columnToHole: [Int: Int] = [:]
        for (colIndex, text) in headerCells.enumerated() {
            if let holeNum = Int(text) {
                columnToHole[colIndex] = holeNum
            }
        }

        guard !columnToHole.isEmpty else {
            throw ScraperError.parseError("No hole numbers found in header row")
        }

        // Storage keyed by hole number
        var parByHole: [Int: Int] = [:]
        var handicapByHole: [Int: Int] = [:]
        var yardagesByHole: [Int: [String: Int]] = [:]
        var teeNames: [String] = []

        let skipLabels: Set<String> = ["out", "in", "tot", "total"]

        for row in rows.dropFirst() {
            let cells = cellTexts(from: row)
            guard !cells.isEmpty else { continue }

            let label = cells[0].trimmingCharacters(in: .whitespaces)
            let normalizedLabel = label.lowercased()

            if skipLabels.contains(normalizedLabel) {
                continue
            }

            if normalizedLabel == "par" {
                for (colIndex, holeNum) in columnToHole {
                    if colIndex < cells.count, let val = Int(cells[colIndex]) {
                        parByHole[holeNum] = val
                    }
                }
            } else if normalizedLabel == "handicap" || normalizedLabel == "hdcp" {
                for (colIndex, holeNum) in columnToHole {
                    if colIndex < cells.count, let val = Int(cells[colIndex]) {
                        handicapByHole[holeNum] = val
                    }
                }
            } else {
                // Tee name row with yardages
                teeNames.append(label)
                for (colIndex, holeNum) in columnToHole {
                    if colIndex < cells.count, let val = Int(cells[colIndex]) {
                        yardagesByHole[holeNum, default: [:]][label] = val
                    }
                }
            }
        }

        // Build Hole objects sorted by hole number
        let sortedHoleNumbers = columnToHole.values.sorted()
        var holes: [Hole] = []
        for holeNum in sortedHoleNumbers {
            let hole = Hole(
                number: holeNum,
                par: parByHole[holeNum] ?? 0,
                handicap: handicapByHole[holeNum] ?? 0,
                yardages: yardagesByHole[holeNum] ?? [:]
            )
            holes.append(hole)
        }

        return ScorecardData(holes: holes, teeNames: teeNames)
    }

    /// Fetches HTML from the given URL via URLSession, then parses it.
    static func fetchAndParse(url: URL) async throws -> ScorecardData {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ScraperError.parseError("Could not decode HTML as UTF-8")
        }
        return try parseGolfLink(html: html)
    }

    /// Extracts text content from td and th elements in a table row.
    private static func cellTexts(from row: XMLElement) -> [String] {
        var texts: [String] = []
        let tdCells = row.elements(forName: "td")
        let thCells = row.elements(forName: "th")

        // Use whichever cell type is present (th for headers, td for data)
        let cells = thCells.isEmpty ? tdCells : thCells
        // If a row has both th and td, combine them in document order
        if !thCells.isEmpty && !tdCells.isEmpty {
            // Fall back to iterating all children to preserve order
            guard let children = row.children else { return texts }
            for child in children {
                if let element = child as? XMLElement,
                   (element.name == "td" || element.name == "th") {
                    texts.append(element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                }
            }
            return texts
        }

        for cell in cells {
            texts.append(cell.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return texts
    }
}

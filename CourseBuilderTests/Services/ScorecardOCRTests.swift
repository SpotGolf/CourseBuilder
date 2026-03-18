import XCTest
@testable import CourseBuilder
@testable import CourseData

final class ScorecardOCRTests: XCTestCase {

    // MARK: - Helper

    /// Creates a TextBlock at a given normalized position.
    private func block(_ text: String, x: CGFloat, y: CGFloat) -> ScorecardOCR.TextBlock {
        ScorecardOCR.TextBlock(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: 0.05, height: 0.03)
        )
    }

    /// Builds a row of blocks: label at x=0, then values at evenly spaced x positions.
    private func row(_ label: String, values: [String], y: CGFloat) -> [ScorecardOCR.TextBlock] {
        var blocks = [block(label, x: 0.0, y: y)]
        for (i, val) in values.enumerated() {
            blocks.append(block(val, x: 0.1 + CGFloat(i) * 0.08, y: y))
        }
        return blocks
    }

    // MARK: - Par Parsing

    func testParsesPar() {
        let blocks = row("Men's Par", values: ["4", "5", "4", "3", "4", "4", "5", "4", "3"], y: 0.5)
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.count, 9)
        XCTAssertEqual(data.holes.map(\.par), [4, 5, 4, 3, 4, 4, 5, 4, 3])
    }

    func testFiltersParOutOfRange() {
        // Totals like 36 should be filtered out of par values
        let blocks = row("Par", values: ["4", "5", "3", "36"], y: 0.5)
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.count, 3)
        XCTAssertEqual(data.holes.map(\.par), [4, 5, 3])
    }

    func testUsesFirstParRow() {
        // Men's Par comes first, Women's Par should not overwrite
        let mensPar = row("Men's Par", values: ["4", "5", "4"], y: 0.6)
        let womensPar = row("Women's Par", values: ["3", "4", "3"], y: 0.4)
        let blocks = mensPar + womensPar
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.map(\.par), [4, 5, 4])
    }

    // MARK: - Handicap Parsing

    func testParsesMaleAndFemaleHandicaps() {
        let par = row("Par", values: ["4", "5", "3"], y: 0.7)
        let mensHdcp = row("Men's Handicap", values: ["1", "3", "5"], y: 0.6)
        let womensHdcp = row("Women's Handicap", values: ["2", "4", "6"], y: 0.4)
        let blocks = par + mensHdcp + womensHdcp
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.map(\.maleHandicap), [1, 3, 5])
        XCTAssertEqual(data.holes.map(\.femaleHandicap), [2, 4, 6])
    }

    func testParsesLadiesHandicap() {
        let par = row("Par", values: ["4", "5"], y: 0.7)
        let ladiesHdcp = row("Ladies Hdcp", values: ["2", "8"], y: 0.5)
        let blocks = par + ladiesHdcp
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.map(\.femaleHandicap), [2, 8])
    }

    func testFiltersHandicapOutOfRange() {
        let par = row("Par", values: ["4", "5", "3"], y: 0.7)
        // "36" is out of 1-18 range and should be filtered
        let hdcp = row("Handicap", values: ["1", "3", "36"], y: 0.5)
        let blocks = par + hdcp
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.map(\.maleHandicap), [1, 3, 0])
    }

    // MARK: - Tee Parsing

    func testParsesTeeYardages() {
        let blueRow = row("Blue", values: ["431", "558", "433"], y: 0.8)
        let par = row("Par", values: ["4", "5", "4"], y: 0.5)
        let blocks = blueRow + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.teeNames, ["Blue"])
        XCTAssertEqual(data.holes[0].yardages["Blue"], 431)
        XCTAssertEqual(data.holes[1].yardages["Blue"], 558)
        XCTAssertEqual(data.holes[2].yardages["Blue"], 433)
    }

    func testFiltersTotalYardages() {
        // Values >= 1000 (like "3,516") should be excluded from hole yardages
        let blueRow = row("Blue", values: ["431", "558", "433", "3516"], y: 0.8)
        let par = row("Par", values: ["4", "5", "4"], y: 0.5)
        let blocks = blueRow + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.count, 3)
        XCTAssertEqual(data.teeNames, ["Blue"])
    }

    // MARK: - Header/Summary Filtering

    func testSkipsHoleHeaderRow() {
        let header = row("Hole", values: ["1", "2", "3"], y: 0.9)
        let par = row("Par", values: ["4", "5", "4"], y: 0.5)
        let blocks = header + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        // "Hole" row should not appear as a tee
        XCTAssertTrue(data.teeNames.isEmpty)
        XCTAssertEqual(data.holes.count, 3)
    }

    func testSkipsHolePrefixVariants() {
        // "Hole1" merged by OCR should also be skipped
        let header = row("Hole1", values: ["2", "3"], y: 0.9)
        let par = row("Par", values: ["4", "5", "4"], y: 0.5)
        let blocks = header + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertTrue(data.teeNames.isEmpty)
    }

    func testFiltersSummaryColumns() {
        // "Out" and "Total" tokens should be excluded
        let par = row("Par", values: ["4", "5", "3", "Out", "36", "Total", "36"], y: 0.5)
        let blocks = par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        // Only 4, 5, 3 are valid par values (36 is filtered by range)
        XCTAssertEqual(data.holes.map(\.par), [4, 5, 3])
    }

    // MARK: - Merged Text Splitting

    func testSplitsMergedTextBlocks() {
        // Vision sometimes merges adjacent cells: "458 335"
        let teeRow: [ScorecardOCR.TextBlock] = [
            block("Green", x: 0.0, y: 0.3),
            block("329", x: 0.1, y: 0.3),
            block("458 335", x: 0.2, y: 0.3),
            block("114", x: 0.35, y: 0.3),
        ]
        let par = row("Par", values: ["4", "5", "4", "3"], y: 0.5)
        let blocks = teeRow + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes[0].yardages["Green"], 329)
        XCTAssertEqual(data.holes[1].yardages["Green"], 458)
        XCTAssertEqual(data.holes[2].yardages["Green"], 335)
        XCTAssertEqual(data.holes[3].yardages["Green"], 114)
    }

    func testTrimsLeadingTrailingNonDigits() {
        // "| 306" should become 306
        let teeRow: [ScorecardOCR.TextBlock] = [
            block("Gold", x: 0.0, y: 0.3),
            block("| 306", x: 0.1, y: 0.3),
            block("210", x: 0.2, y: 0.3),
            block("514", x: 0.3, y: 0.3),
        ]
        let par = row("Par", values: ["4", "3", "5"], y: 0.5)
        let blocks = teeRow + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes[0].yardages["Gold"], 306)
    }

    func testRejectsMidStringCorruption() {
        // "3S5" has non-digit between digits — trimming gives "3S5" which Int() rejects.
        // The rejected token is dropped, so remaining values shift left:
        // holes get [210, 150, 300] mapped to positions [0, 1, 2].
        let teeRow: [ScorecardOCR.TextBlock] = [
            block("Red", x: 0.0, y: 0.3),
            block("3S5", x: 0.1, y: 0.3),
            block("210", x: 0.2, y: 0.3),
            block("150", x: 0.3, y: 0.3),
            block("300", x: 0.4, y: 0.3),
        ]
        let par = row("Par", values: ["4", "3", "4", "5"], y: 0.5)
        let blocks = teeRow + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        // "3S5" is rejected, 3 valid yardages remain
        XCTAssertEqual(data.holes[0].yardages["Red"], 210)
        XCTAssertEqual(data.holes[1].yardages["Red"], 150)
        XCTAssertEqual(data.holes[2].yardages["Red"], 300)
        XCTAssertNil(data.holes[3].yardages["Red"])
    }

    // MARK: - Edge Cases

    func testEmptyBlocksReturnsEmptyData() {
        let data = ScorecardOCR.parseScorecardData(from: [])
        XCTAssertTrue(data.holes.isEmpty)
        XCTAssertTrue(data.teeNames.isEmpty)
    }

    func testHoleCountFromLargestDataSource() {
        // Par has 3 values, tee has 4 — hole count should be 4
        let teeRow = row("Blue", values: ["400", "350", "300", "250"], y: 0.8)
        let par = row("Par", values: ["4", "5", "3"], y: 0.5)
        let blocks = teeRow + par
        let data = ScorecardOCR.parseScorecardData(from: blocks)
        XCTAssertEqual(data.holes.count, 4)
        XCTAssertEqual(data.holes[3].par, 0) // No par data for hole 4
        XCTAssertEqual(data.holes[3].yardages["Blue"], 250)
    }
}

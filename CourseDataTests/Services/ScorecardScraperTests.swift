import XCTest
@testable import CourseData

final class ScorecardScraperTests: XCTestCase {
    func testParseGolfLinkHTML() throws {
        // Minimal GolfLink-style scorecard HTML
        let html = """
        <div class="scorecard-table-container">
        <table>
          <tr><th></th><th>1</th><th>2</th><th>3</th><th>Out</th></tr>
          <tr><td>Black</td><td>401</td><td>545</td><td>185</td><td>1131</td></tr>
          <tr><td>Gold</td><td>378</td><td>520</td><td>165</td><td>1063</td></tr>
          <tr><td>Par</td><td>4</td><td>5</td><td>3</td><td>12</td></tr>
          <tr><td>Handicap</td><td>13</td><td>3</td><td>17</td><td></td></tr>
        </table>
        </div>
        """

        let result = try ScorecardScraper.parseGolfLink(html: html)
        XCTAssertEqual(result.holes.count, 3)
        XCTAssertEqual(result.holes[0].par, 4)
        XCTAssertEqual(result.holes[0].handicap, 13)
        XCTAssertEqual(result.holes[0].yardages["Black"], 401)
        XCTAssertEqual(result.holes[0].yardages["Gold"], 378)
        XCTAssertEqual(result.holes[1].par, 5)
        XCTAssertEqual(result.holes[2].yardages["Black"], 185)
        XCTAssertEqual(result.teeNames, ["Black", "Gold"])
    }
}

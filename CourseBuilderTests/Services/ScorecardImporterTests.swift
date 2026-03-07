import XCTest
@testable import CourseBuilder

@MainActor
final class ScorecardImporterTests: XCTestCase {
    func testBuildCourseFromScorecardData() {
        let holes = (1...18).map { number in
            Hole(number: number, par: number <= 9 ? 4 : 5, yardages: ["Blue": 400])
        }
        let data = ScorecardData(holes: holes, teeNames: ["Blue", "White"])

        let importer = ScorecardImporter(apiKey: nil)
        let course = importer.buildCourse(from: data, name: "Test", city: "Denver", state: "CO")

        XCTAssertEqual(course.name, "Test")
        XCTAssertEqual(course.subCourses.count, 2)
        XCTAssertEqual(course.subCourses[0].name, "Front")
        XCTAssertEqual(course.subCourses[0].holes.count, 9)
        XCTAssertEqual(course.subCourses[1].name, "Back")
        XCTAssertEqual(course.subCourses[1].holes.count, 9)
        XCTAssertEqual(course.tees.count, 2)
        // Holes renumbered 1-9
        XCTAssertEqual(course.subCourses[1].holes[0].number, 1)
    }

    func testBuildCourseSortsTeesByDescendingTotalYardage() {
        // Blue: 500 total, Black: 580 total, Red: 400 total
        // Input order: Blue, Black, Red (not sorted)
        // Expected output: Black, Blue, Red (descending by total yardage)
        let holes = (1...9).map { number in
            Hole(
                number: number,
                par: 4,
                yardages: [
                    "Blue": 55 + number,   // sum ≈ 540 ... actually let's be explicit
                    "Black": 64 + number,
                    "Red": 44 + number,
                ]
            )
        }
        // Blue total: 56+57+58+59+60+61+62+63+64 = 540
        // Black total: 65+66+67+68+69+70+71+72+73 = 621
        // Red total: 45+46+47+48+49+50+51+52+53 = 441
        let data = ScorecardData(holes: holes, teeNames: ["Blue", "Black", "Red"])

        let importer = ScorecardImporter(apiKey: nil)
        let course = importer.buildCourse(from: data, name: "Test", city: "Denver", state: "CO")

        XCTAssertEqual(course.tees.map(\.name), ["Black", "Blue", "Red"])
    }

    func testBuildCourse9Holes() {
        let holes = (1...9).map { Hole(number: $0, par: 4) }
        let data = ScorecardData(holes: holes, teeNames: ["Blue"])

        let importer = ScorecardImporter(apiKey: nil)
        let course = importer.buildCourse(from: data, name: "Nine", city: "Denver", state: "CO")

        XCTAssertEqual(course.subCourses.count, 1)
        XCTAssertEqual(course.subCourses[0].holes.count, 9)
    }
}

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

    func testBuildCourse9Holes() {
        let holes = (1...9).map { Hole(number: $0, par: 4) }
        let data = ScorecardData(holes: holes, teeNames: ["Blue"])

        let importer = ScorecardImporter(apiKey: nil)
        let course = importer.buildCourse(from: data, name: "Nine", city: "Denver", state: "CO")

        XCTAssertEqual(course.subCourses.count, 1)
        XCTAssertEqual(course.subCourses[0].holes.count, 9)
    }
}

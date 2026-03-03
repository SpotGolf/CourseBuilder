import XCTest
@testable import CourseData

final class CourseTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let course = Course(
            id: "broadlands-gc-broomfield-co",
            name: "The Broadlands Golf Course",
            location: CourseLocation(
                city: "Broomfield",
                state: "CO",
                coordinate: Coordinate(latitude: 39.9397, longitude: -105.0267)
            ),
            tees: [
                TeeDefinition(name: "Black", color: "#000000", gender: .male, rating: 73.5, slope: 137),
                TeeDefinition(name: "Gold", color: "#FFD700", gender: .male, rating: 71.2, slope: 131)
            ],
            holes: [
                Hole(number: 1, par: 4, handicap: 13,
                     yardages: ["Black": 401],
                     tees: ["Black": Coordinate(latitude: 39.9401, longitude: -105.0271)])
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(course)
        let decoded = try JSONDecoder().decode(Course.self, from: data)

        XCTAssertEqual(course.id, decoded.id)
        XCTAssertEqual(course.name, decoded.name)
        XCTAssertEqual(course.location.city, "Broomfield")
        XCTAssertEqual(course.tees.count, 2)
        XCTAssertEqual(course.holes.count, 1)
    }

    func testEmptyCourse() {
        let course = Course(
            id: "test",
            name: "Test Course",
            location: CourseLocation(
                city: "Denver",
                state: "CO",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            )
        )
        XCTAssertTrue(course.tees.isEmpty)
        XCTAssertTrue(course.holes.isEmpty)
    }

    func testGenerateID() {
        let id = Course.generateID(name: "The Broadlands Golf Course", city: "Broomfield", state: "CO")
        XCTAssertEqual(id, "the-broadlands-golf-course-broomfield-co")
    }
}

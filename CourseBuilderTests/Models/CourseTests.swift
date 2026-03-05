import XCTest
@testable import CourseBuilder

final class CourseTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let course = Course(
            name: "The Broadlands Golf Course",
            location: CourseLocation(
                address: "4380 W 144th Ave",
                city: "Broomfield",
                state: "CO",
                country: "US",
                coordinate: Coordinate(latitude: 39.9397, longitude: -105.0267)
            ),
            tees: [
                TeeDefinition(name: "Black", color: "#000000"),
                TeeDefinition(name: "Gold", color: "#FFD700")
            ],
            subCourses: [
                SubCourse(
                    name: "Front",
                    holes: [
                        Hole(number: 1, par: 4, maleHandicap: 13,
                             yardages: ["Black": 401],
                             tees: ["Black": Coordinate(latitude: 39.9401, longitude: -105.0271)])
                    ],
                    tees: ["Black": SubCourseTee(male: TeeInformation(rating: 37.6, slope: 134))]
                )
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
        XCTAssertEqual(course.subCourses.count, 1)
        XCTAssertEqual(course.subCourses[0].name, "Front")
        XCTAssertEqual(course.subCourses[0].holes.count, 1)
        XCTAssertEqual(course.subCourses[0].tees["Black"]?.male?.rating, 37.6)
    }

    func testEmptyCourse() {
        let course = Course(
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Denver",
                state: "CO",
                country: "",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            )
        )
        XCTAssertTrue(course.tees.isEmpty)
        XCTAssertTrue(course.subCourses.isEmpty)
    }
}

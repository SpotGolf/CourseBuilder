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
            features: [
                Feature(id: 1, type: .tee, polygon: [
                    Coordinate(latitude: 39.9401, longitude: -105.0271),
                    Coordinate(latitude: 39.9402, longitude: -105.0272),
                    Coordinate(latitude: 39.9401, longitude: -105.0273)
                ]),
                Feature(id: 2, type: .fairway, polygon: [
                    Coordinate(latitude: 39.939, longitude: -105.026),
                    Coordinate(latitude: 39.938, longitude: -105.025)
                ])
            ],
            subCourses: [
                SubCourse(
                    name: "Front",
                    holes: [
                        Hole(number: 1, par: 4, maleHandicap: 13,
                             yardages: ["Black": 401],
                             featureIDs: [1, 2])
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
        XCTAssertEqual(course.features.count, 2)
        XCTAssertEqual(course.features[0].type, .tee)
        XCTAssertEqual(course.features[1].type, .fairway)
        XCTAssertEqual(course.subCourses.count, 1)
        XCTAssertEqual(course.subCourses[0].holes[0].featureIDs, [1, 2])
        XCTAssertEqual(course.subCourses[0].tees["Black"]?.male?.rating, 37.6)
    }

    func testTeeDefinitionHasNoIdInJSON() throws {
        let tee = TeeDefinition(name: "Blue", color: "#0000FF")
        let data = try JSONEncoder().encode(tee)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["id"])
        XCTAssertEqual(json["name"] as? String, "Blue")
        XCTAssertEqual(json["color"] as? String, "#0000FF")
    }

    func testDefaultTeeColors() {
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Black"), "#000000")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "BLUE"), "#0000FF")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Red"), "#FF0000")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "White"), "#FFFFFF")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Gold"), "#FFD700")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Silver"), "#C0C0C0")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Green"), "#008000")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Unknown"), "#808080")
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
        XCTAssertTrue(course.features.isEmpty)
        XCTAssertTrue(course.subCourses.isEmpty)
    }

    func testNextFeatureID() {
        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "", coordinate: Coordinate(latitude: 0, longitude: 0)),
            features: [
                Feature(id: 1, type: .fairway, polygon: []),
                Feature(id: 5, type: .green, polygon: []),
                Feature(id: 3, type: .bunker, polygon: [])
            ]
        )
        XCTAssertEqual(course.nextFeatureID, 6)

        course.features = []
        XCTAssertEqual(course.nextFeatureID, 1)
    }
}

import XCTest
@testable import CourseBuilder

final class OSMImporterTests: XCTestCase {
    func testAssociateFeaturesViaCenterlines() {
        let fairway = OverpassAPIClient.ParsedFeature(
            type: .fairway,
            polygon: [
                Coordinate(latitude: 39.786, longitude: -74.958),
                Coordinate(latitude: 39.786, longitude: -74.956),
                Coordinate(latitude: 39.788, longitude: -74.956),
                Coordinate(latitude: 39.788, longitude: -74.958)
            ]
        )
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(latitude: 39.784, longitude: -74.955),
                Coordinate(latitude: 39.784, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.955)
            ]
        )
        let centerline = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.790, longitude: -74.960),
                Coordinate(latitude: 39.787, longitude: -74.957),
                Coordinate(latitude: 39.7845, longitude: -74.954)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [fairway, green],
            centerlines: [centerline],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        XCTAssertEqual(course.features.count, 2)
        XCTAssertFalse(course.subCourses[0].holes[0].featureIDs.isEmpty)
        XCTAssertFalse(course.subCourses[0].holes[0].centerline.isEmpty)
    }

    func testGeneratesCenterlinesWhenMissing() {
        let tee = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(latitude: 39.790, longitude: -74.960),
                Coordinate(latitude: 39.791, longitude: -74.960),
                Coordinate(latitude: 39.791, longitude: -74.959),
                Coordinate(latitude: 39.790, longitude: -74.959)
            ]
        )
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(latitude: 39.784, longitude: -74.955),
                Coordinate(latitude: 39.784, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.955)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [tee, green],
            centerlines: [],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        XCTAssertFalse(course.subCourses[0].holes[0].centerline.isEmpty)
        XCTAssertEqual(course.subCourses[0].holes[0].featureIDs.count, 2)
    }
}

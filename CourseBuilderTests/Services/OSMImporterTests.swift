import XCTest
@testable import CourseBuilder

final class OSMImporterTests: XCTestCase {
    func testAssociateFeaturesViaCenterlines() {
        // Fairway centroid sits right on the centerline path
        let fairway = OverpassAPIClient.ParsedFeature(
            type: .fairway,
            polygon: [
                Coordinate(latitude: 39.7869, longitude: -74.9571),
                Coordinate(latitude: 39.7869, longitude: -74.9569),
                Coordinate(latitude: 39.7871, longitude: -74.9569),
                Coordinate(latitude: 39.7871, longitude: -74.9571)
            ]
        )
        // Green centroid sits at the centerline endpoint
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(latitude: 39.7844, longitude: -74.9541),
                Coordinate(latitude: 39.7844, longitude: -74.9539),
                Coordinate(latitude: 39.7846, longitude: -74.9539),
                Coordinate(latitude: 39.7846, longitude: -74.9541)
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
        XCTAssertEqual(course.subCourses[0].holes[0].features.count, 2)
        XCTAssertFalse(course.subCourses[0].holes[0].centerline.isEmpty)
    }

    func testAssignsFeatureToCorrectHole() {
        // Green centroid (~39.7901, ~-74.9401) is right at hole 2's centerline endpoint,
        // far from hole 1's centerline
        let greenNearHole2 = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(latitude: 39.7900, longitude: -74.9402),
                Coordinate(latitude: 39.7900, longitude: -74.9400),
                Coordinate(latitude: 39.7902, longitude: -74.9400),
                Coordinate(latitude: 39.7902, longitude: -74.9402)
            ]
        )
        let cl1 = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.787, longitude: -74.960),
                Coordinate(latitude: 39.787, longitude: -74.955)
            ]
        )
        let cl2 = OverpassAPIClient.ParsedCenterline(
            holeNumber: 2,
            coordinates: [
                Coordinate(latitude: 39.790, longitude: -74.945),
                Coordinate(latitude: 39.7901, longitude: -74.9401)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [greenNearHole2],
            centerlines: [cl1, cl2],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4), Hole(number: 2, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        // Green should be assigned to hole 2 only
        XCTAssertTrue(course.subCourses[0].holes[0].features.isEmpty)
        XCTAssertEqual(course.subCourses[0].holes[1].features.count, 1)
    }

    func testFeatureBeyondThresholdNotAssigned() {
        // Feature centroid is far from the centerline (> 20 yards)
        let bunkerFarAway = OverpassAPIClient.ParsedFeature(
            type: .bunker,
            polygon: [
                Coordinate(latitude: 39.800, longitude: -74.930),
                Coordinate(latitude: 39.800, longitude: -74.929),
                Coordinate(latitude: 39.801, longitude: -74.929),
                Coordinate(latitude: 39.801, longitude: -74.930)
            ]
        )
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.787, longitude: -74.960),
                Coordinate(latitude: 39.787, longitude: -74.955)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [bunkerFarAway],
            centerlines: [cl],
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

        // Bunker is too far from any centerline — should not be assigned
        XCTAssertTrue(course.subCourses[0].holes[0].features.isEmpty)
        // But it should still exist as a course-level feature
        XCTAssertEqual(course.features.count, 1)
    }

    func testCenterlinePassesThroughPolygon() {
        // Large fairway polygon — centerline passes through it but centroid is > 20 yards away
        let fairway = OverpassAPIClient.ParsedFeature(
            type: .fairway,
            polygon: [
                Coordinate(latitude: 39.786, longitude: -74.960),
                Coordinate(latitude: 39.786, longitude: -74.950),
                Coordinate(latitude: 39.788, longitude: -74.950),
                Coordinate(latitude: 39.788, longitude: -74.960)
            ]
        )
        // Centerline enters the polygon from one side
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.787, longitude: -74.965),
                Coordinate(latitude: 39.787, longitude: -74.955)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [fairway],
            centerlines: [cl],
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

        // Fairway should be assigned because centerline endpoint is inside the polygon
        XCTAssertEqual(course.subCourses[0].holes[0].features.count, 1)
    }

    func testFeatureOffsetFromCenterline() {
        // Bunker polygon sits to the side of the centerline, within 20 yards
        // Centroid is offset but a vertex is close to the centerline
        let bunker = OverpassAPIClient.ParsedFeature(
            type: .bunker,
            polygon: [
                Coordinate(latitude: 39.7872, longitude: -74.957),
                Coordinate(latitude: 39.7872, longitude: -74.9565),
                Coordinate(latitude: 39.7875, longitude: -74.9565),
                Coordinate(latitude: 39.7875, longitude: -74.957)
            ]
        )
        // Centerline runs horizontally just below the bunker
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.787, longitude: -74.960),
                Coordinate(latitude: 39.787, longitude: -74.955)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [bunker],
            centerlines: [cl],
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

        // Bunker's nearest vertex is ~0.0002° lat from centerline ≈ 22m ≈ ~24 yards
        // which is within the 35-yard threshold, so it should be assigned
        XCTAssertEqual(course.subCourses[0].holes[0].features.count, 1)
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
        XCTAssertEqual(course.subCourses[0].holes[0].features.count, 2)
    }

    // MARK: - Tee Name Assignment

    func testAssignsTeeNamesWhenCountsMatch() {
        // 3 tee polygons at different distances from the green, 3 tee names with yardages.
        // Should zip by rank: longest polygon → highest yardage name.

        // Green at ~39.784, ~-74.954
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(latitude: 39.784, longitude: -74.955),
                Coordinate(latitude: 39.784, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.955)
            ]
        )
        // Tee closest to green (~200 yards)
        let teeClose = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(latitude: 39.786, longitude: -74.956),
                Coordinate(latitude: 39.786, longitude: -74.955),
                Coordinate(latitude: 39.787, longitude: -74.955),
                Coordinate(latitude: 39.787, longitude: -74.956)
            ]
        )
        // Tee mid distance (~400 yards)
        let teeMid = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(latitude: 39.788, longitude: -74.958),
                Coordinate(latitude: 39.788, longitude: -74.957),
                Coordinate(latitude: 39.789, longitude: -74.957),
                Coordinate(latitude: 39.789, longitude: -74.958)
            ]
        )
        // Tee farthest from green (~600 yards)
        let teeFar = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(latitude: 39.790, longitude: -74.960),
                Coordinate(latitude: 39.790, longitude: -74.959),
                Coordinate(latitude: 39.791, longitude: -74.959),
                Coordinate(latitude: 39.791, longitude: -74.960)
            ]
        )
        let centerline = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.791, longitude: -74.960),
                Coordinate(latitude: 39.788, longitude: -74.957),
                Coordinate(latitude: 39.7845, longitude: -74.954)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [green, teeClose, teeMid, teeFar],
            centerlines: [centerline],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
            tees: [
                TeeDefinition(name: "Black", color: "#000000"),
                TeeDefinition(name: "White", color: "#FFFFFF"),
                TeeDefinition(name: "Red", color: "#FF0000")
            ],
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )
        course.subCourses[0].holes[0].yardages = ["Black": 550, "White": 400, "Red": 250]

        OSMImporter.applyParsedResult(parsed, to: &course)

        let hole = course.subCourses[0].holes[0]
        // Farthest tee → Black (highest yardage)
        // Mid tee → White
        // Closest tee → Red (lowest yardage)
        let teeFeatures = course.features.filter { $0.type == .tee }
        let farFeatureID = teeFeatures.first(where: { $0.polygon[0].latitude > 39.7895 })!.id
        let midFeatureID = teeFeatures.first(where: {
            $0.polygon[0].latitude > 39.7875 && $0.polygon[0].latitude < 39.7895
        })!.id
        let closeFeatureID = teeFeatures.first(where: { $0.polygon[0].latitude < 39.7875 })!.id

        XCTAssertEqual(hole.tees["Black"], farFeatureID)
        XCTAssertEqual(hole.tees["White"], midFeatureID)
        XCTAssertEqual(hole.tees["Red"], closeFeatureID)
    }

    func testAssignsTeeNamesWhenFewerPolygonsThanNames() {
        // 2 tee polygons but 4 tee names — multiple names should share a polygon.

        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(latitude: 39.784, longitude: -74.955),
                Coordinate(latitude: 39.784, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.955)
            ]
        )
        // Back tee box (farther from green)
        let teeBack = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(latitude: 39.790, longitude: -74.960),
                Coordinate(latitude: 39.790, longitude: -74.959),
                Coordinate(latitude: 39.791, longitude: -74.959),
                Coordinate(latitude: 39.791, longitude: -74.960)
            ]
        )
        // Front tee box (closer to green)
        let teeFront = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(latitude: 39.786, longitude: -74.956),
                Coordinate(latitude: 39.786, longitude: -74.955),
                Coordinate(latitude: 39.787, longitude: -74.955),
                Coordinate(latitude: 39.787, longitude: -74.956)
            ]
        )
        let centerline = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.791, longitude: -74.960),
                Coordinate(latitude: 39.788, longitude: -74.957),
                Coordinate(latitude: 39.7845, longitude: -74.954)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [green, teeBack, teeFront],
            centerlines: [centerline],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
            tees: [
                TeeDefinition(name: "Black", color: "#000000"),
                TeeDefinition(name: "Blue", color: "#0000FF"),
                TeeDefinition(name: "White", color: "#FFFFFF"),
                TeeDefinition(name: "Red", color: "#FF0000")
            ],
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )
        // Back tee box centroid is ~890 yards from green, front is ~280 yards.
        // Black & Blue yardages are close to 890, White & Red close to 280.
        course.subCourses[0].holes[0].yardages = ["Black": 900, "Blue": 880, "White": 290, "Red": 270]

        OSMImporter.applyParsedResult(parsed, to: &course)

        let hole = course.subCourses[0].holes[0]
        let teeFeatures = course.features.filter { $0.type == .tee }
        let backFeatureID = teeFeatures.first(where: { $0.polygon[0].latitude > 39.789 })!.id
        let frontFeatureID = teeFeatures.first(where: { $0.polygon[0].latitude < 39.789 })!.id

        // Black & Blue should share the back tee box
        XCTAssertEqual(hole.tees["Black"], backFeatureID)
        XCTAssertEqual(hole.tees["Blue"], backFeatureID)
        // White & Red should share the front tee box
        XCTAssertEqual(hole.tees["White"], frontFeatureID)
        XCTAssertEqual(hole.tees["Red"], frontFeatureID)
        // All 4 tee names should be assigned
        XCTAssertEqual(hole.tees.count, 4)
    }
}

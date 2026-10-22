import XCTest
@testable import CourseBuilder
import CourseDataSwift

final class OSMImporterTests: XCTestCase {
    func testAssociateFeaturesViaCenterlines() throws {
        // Fairway centroid sits right on the centerline path
        let fairway = OverpassAPIClient.ParsedFeature(
            type: .fairway,
            polygon: [
                Coordinate(lat: 39.7869, lon: -74.9571),
                Coordinate(lat: 39.7869, lon: -74.9569),
                Coordinate(lat: 39.7871, lon: -74.9569),
                Coordinate(lat: 39.7871, lon: -74.9571)
            ],
            osmID: "w1"
        )
        // Green centroid sits at the centerline endpoint
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.7844, lon: -74.9541),
                Coordinate(lat: 39.7844, lon: -74.9539),
                Coordinate(lat: 39.7846, lon: -74.9539),
                Coordinate(lat: 39.7846, lon: -74.9541)
            ],
            osmID: "w2"
        )
        let centerline = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.790, lon: -74.960),
                Coordinate(lat: 39.787, lon: -74.957),
                Coordinate(lat: 39.7845, lon: -74.954)
            ],
            osmID: "w3"
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [fairway, green],
            centerlines: [centerline],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        XCTAssertEqual(course.features.count, 3)
        XCTAssertEqual(course.subCourses[0].holes[0].features.count, 2)
        let centerlineFeature = try XCTUnwrap(course.subCourses[0].holes[0].centerline(from: course.features))
        XCTAssertEqual(centerlineFeature.type, .centerline)
        XCTAssertEqual(centerlineFeature.polygon.count, 3)
        XCTAssertEqual(course.features.map(\.osmID), ["w1", "w2", "w3"])
    }

    func testAssignsFeatureToCorrectHole() {
        // Two greens, two holes. Each green is closest to one hole's centerline endpoint.
        let greenForHole1 = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.787, lon: -74.9552),
                Coordinate(lat: 39.787, lon: -74.9548),
                Coordinate(lat: 39.788, lon: -74.9548),
                Coordinate(lat: 39.788, lon: -74.9552)
            ]
        )
        let greenForHole2 = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.7900, lon: -74.9402),
                Coordinate(lat: 39.7900, lon: -74.9400),
                Coordinate(lat: 39.7902, lon: -74.9400),
                Coordinate(lat: 39.7902, lon: -74.9402)
            ]
        )
        let cl1 = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.787, lon: -74.960),
                Coordinate(lat: 39.787, lon: -74.955)
            ]
        )
        let cl2 = OverpassAPIClient.ParsedCenterline(
            holeNumber: 2,
            coordinates: [
                Coordinate(lat: 39.790, lon: -74.945),
                Coordinate(lat: 39.7901, lon: -74.9401)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [greenForHole1, greenForHole2],
            centerlines: [cl1, cl2],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4), Hole(number: 2, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        let green1ID = course.features.first(where: { $0.type == .green && $0.polygon[0].lat < 39.789 })!.id
        let green2ID = course.features.first(where: { $0.type == .green && $0.polygon[0].lat > 39.789 })!.id

        // Each green should be assigned to its closest hole
        XCTAssertTrue(course.subCourses[0].holes[0].features.contains(green1ID))
        XCTAssertFalse(course.subCourses[0].holes[0].features.contains(green2ID))
        XCTAssertTrue(course.subCourses[0].holes[1].features.contains(green2ID))
        XCTAssertFalse(course.subCourses[0].holes[1].features.contains(green1ID))
    }

    func testFeatureBeyondThresholdNotAssigned() {
        // Feature centroid is far from the centerline (> 20 yards)
        let bunkerFarAway = OverpassAPIClient.ParsedFeature(
            type: .bunker,
            polygon: [
                Coordinate(lat: 39.800, lon: -74.930),
                Coordinate(lat: 39.800, lon: -74.929),
                Coordinate(lat: 39.801, lon: -74.929),
                Coordinate(lat: 39.801, lon: -74.930)
            ]
        )
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.787, lon: -74.960),
                Coordinate(lat: 39.787, lon: -74.955)
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
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        // Bunker is too far from any centerline — should not be assigned
        XCTAssertTrue(course.subCourses[0].holes[0].features.isEmpty)
        // But it should still exist as a course-level feature, next to the centerline
        XCTAssertEqual(course.features.map(\.type), [.bunker, .centerline])
    }

    func testCenterlinePassesThroughPolygon() {
        // Large fairway polygon — centerline passes through it but centroid is > 20 yards away
        let fairway = OverpassAPIClient.ParsedFeature(
            type: .fairway,
            polygon: [
                Coordinate(lat: 39.786, lon: -74.960),
                Coordinate(lat: 39.786, lon: -74.950),
                Coordinate(lat: 39.788, lon: -74.950),
                Coordinate(lat: 39.788, lon: -74.960)
            ]
        )
        // Centerline enters the polygon from one side
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.787, lon: -74.965),
                Coordinate(lat: 39.787, lon: -74.955)
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
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
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
                Coordinate(lat: 39.7872, lon: -74.957),
                Coordinate(lat: 39.7872, lon: -74.9565),
                Coordinate(lat: 39.7875, lon: -74.9565),
                Coordinate(lat: 39.7875, lon: -74.957)
            ]
        )
        // Centerline runs horizontally just below the bunker
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.787, lon: -74.960),
                Coordinate(lat: 39.787, lon: -74.955)
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
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
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
                Coordinate(lat: 39.790, lon: -74.960),
                Coordinate(lat: 39.791, lon: -74.960),
                Coordinate(lat: 39.791, lon: -74.959),
                Coordinate(lat: 39.790, lon: -74.959)
            ]
        )
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.784, lon: -74.955),
                Coordinate(lat: 39.784, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.955)
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
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        XCTAssertFalse(course.centerlinePath(for: course.subCourses[0].holes[0]).isEmpty)
        XCTAssertNil(course.subCourses[0].holes[0].centerline(from: course.features)?.osmID)
        XCTAssertEqual(course.subCourses[0].holes[0].features.count, 2)
    }

    // MARK: - Tee Boxes

    func testAssociatesEveryTeeBoxWithTheHole() {
        // 3 tee polygons but only 1 tee name. Tee boxes are not tied to tee names, so all 3
        // belong to the hole.

        // Green at ~39.784, ~-74.954
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.784, lon: -74.955),
                Coordinate(lat: 39.784, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.955)
            ]
        )
        // Tee closest to green (~200 yards)
        let teeClose = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(lat: 39.786, lon: -74.956),
                Coordinate(lat: 39.786, lon: -74.955),
                Coordinate(lat: 39.787, lon: -74.955),
                Coordinate(lat: 39.787, lon: -74.956)
            ]
        )
        // Tee mid distance (~400 yards)
        let teeMid = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(lat: 39.788, lon: -74.958),
                Coordinate(lat: 39.788, lon: -74.957),
                Coordinate(lat: 39.789, lon: -74.957),
                Coordinate(lat: 39.789, lon: -74.958)
            ]
        )
        // Tee farthest from green (~600 yards)
        let teeFar = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(lat: 39.790, lon: -74.960),
                Coordinate(lat: 39.790, lon: -74.959),
                Coordinate(lat: 39.791, lon: -74.959),
                Coordinate(lat: 39.791, lon: -74.960)
            ]
        )
        let centerline = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.791, lon: -74.960),
                Coordinate(lat: 39.788, lon: -74.957),
                Coordinate(lat: 39.7845, lon: -74.954)
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
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
            tees: [TeeDefinition(name: "White", color: "#FFFFFF")],
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )
        course.subCourses[0].holes[0].yardages = ["White": 600]

        OSMImporter.applyParsedResult(parsed, to: &course)

        let hole = course.subCourses[0].holes[0]
        let teeFeatureIDs = course.features.filter { $0.type == .tee }.map(\.id)
        XCTAssertEqual(teeFeatureIDs.count, 3)
        XCTAssertEqual(hole.teeBoxes(from: course.features).map(\.id).sorted(), teeFeatureIDs.sorted())
    }

    // MARK: - Phase-Based Association

    func testGreenAnchoredByCenterlineEndpointContainment() {
        let green1 = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.784, lon: -74.955),
                Coordinate(lat: 39.784, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.955)
            ]
        )
        let green2 = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.790, lon: -74.945),
                Coordinate(lat: 39.790, lon: -74.943),
                Coordinate(lat: 39.791, lon: -74.943),
                Coordinate(lat: 39.791, lon: -74.945)
            ]
        )
        let cl1 = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.790, lon: -74.960),
                Coordinate(lat: 39.7845, lon: -74.954)
            ]
        )
        let cl2 = OverpassAPIClient.ParsedCenterline(
            holeNumber: 2,
            coordinates: [
                Coordinate(lat: 39.784, lon: -74.950),
                Coordinate(lat: 39.7905, lon: -74.944)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [green1, green2],
            centerlines: [cl1, cl2],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(lat: 39.787, lon: -74.950)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4), Hole(number: 2, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        let hole1 = course.subCourses[0].holes[0]
        let hole2 = course.subCourses[0].holes[1]
        let green1ID = course.features.first(where: {
            $0.type == .green && $0.polygon[0].lat < 39.786
        })!.id
        let green2ID = course.features.first(where: {
            $0.type == .green && $0.polygon[0].lat > 39.789
        })!.id

        XCTAssertTrue(hole1.features.contains(green1ID))
        XCTAssertFalse(hole1.features.contains(green2ID))
        XCTAssertTrue(hole2.features.contains(green2ID))
        XCTAssertFalse(hole2.features.contains(green1ID))
    }

    func testTeesAnchoredAlongCenterline() {
        let teeAtStart1 = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(lat: 39.7898, lon: -74.9602),
                Coordinate(lat: 39.7898, lon: -74.9598),
                Coordinate(lat: 39.7902, lon: -74.9598),
                Coordinate(lat: 39.7902, lon: -74.9602)
            ]
        )
        let teeAtStart2 = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(lat: 39.7897, lon: -74.9602),
                Coordinate(lat: 39.7897, lon: -74.9598),
                Coordinate(lat: 39.7901, lon: -74.9598),
                Coordinate(lat: 39.7901, lon: -74.9602)
            ]
        )
        // Junior tee: far forward along the centerline, near midpoint
        let teeJunior = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(lat: 39.7868, lon: -74.9572),
                Coordinate(lat: 39.7868, lon: -74.9568),
                Coordinate(lat: 39.7872, lon: -74.9568),
                Coordinate(lat: 39.7872, lon: -74.9572)
            ]
        )
        // Tee from a different hole — laterally far from this centerline
        let teeDifferentHole = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(lat: 39.780, lon: -74.950),
                Coordinate(lat: 39.780, lon: -74.949),
                Coordinate(lat: 39.781, lon: -74.949),
                Coordinate(lat: 39.781, lon: -74.950)
            ]
        )
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.784, lon: -74.955),
                Coordinate(lat: 39.784, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.955)
            ]
        )
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.790, lon: -74.960),
                Coordinate(lat: 39.787, lon: -74.957),
                Coordinate(lat: 39.7845, lon: -74.954)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [teeAtStart1, teeAtStart2, teeJunior, teeDifferentHole, green],
            centerlines: [cl],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        let hole = course.subCourses[0].holes[0]
        let differentHoleTeeID = course.features.first(where: {
            $0.type == .tee && $0.polygon[0].lat < 39.785
        })!.id

        let holeTeeIDs = hole.features.filter { id in
            course.features.first { $0.id == id }?.type == .tee
        }
        XCTAssertEqual(holeTeeIDs.count, 3)
        XCTAssertFalse(holeTeeIDs.contains(differentHoleTeeID))
    }

    // MARK: - Directional Filter

    func testFeatureBehindCenterlineStartNotAssociated() {
        let bunkerBehind = OverpassAPIClient.ParsedFeature(
            type: .bunker,
            polygon: [
                Coordinate(lat: 39.792, lon: -74.962),
                Coordinate(lat: 39.792, lon: -74.961),
                Coordinate(lat: 39.793, lon: -74.961),
                Coordinate(lat: 39.793, lon: -74.962)
            ]
        )
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(lat: 39.784, lon: -74.955),
                Coordinate(lat: 39.784, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.953),
                Coordinate(lat: 39.785, lon: -74.955)
            ]
        )
        let cl = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(lat: 39.790, lon: -74.960),
                Coordinate(lat: 39.787, lon: -74.957),
                Coordinate(lat: 39.7845, lon: -74.954)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [bunkerBehind, green],
            centerlines: [cl],
            courseBoundary: nil
        )

        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "",
                                     coordinate: Coordinate(lat: 39.787, lon: -74.957)),
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )

        OSMImporter.applyParsedResult(parsed, to: &course)

        let hole = course.subCourses[0].holes[0]
        let bunkerID = course.features.first(where: { $0.type == .bunker })!.id
        XCTAssertFalse(hole.features.contains(bunkerID))
        XCTAssertEqual(hole.features.count, 1) // only the green
    }

    func testPointForwardOfCenterlineStart() {
        // Centerline goes south-east: (39.790, -74.960) → (39.784, -74.954)
        let centerline: CoordinatePath = [
            Coordinate(lat: 39.790, lon: -74.960),
            Coordinate(lat: 39.784, lon: -74.954)
        ]
        // Point along the centerline direction (south-east of start)
        let forward = Coordinate(lat: 39.788, lon: -74.958)
        XCTAssertTrue(OSMImporter.isForwardOfStart(point: forward, centerline: centerline))
    }

    func testPointBehindCenterlineStart() {
        let centerline: CoordinatePath = [
            Coordinate(lat: 39.790, lon: -74.960),
            Coordinate(lat: 39.784, lon: -74.954)
        ]
        // Point behind start (north-west of start, opposite to centerline direction)
        let behind = Coordinate(lat: 39.792, lon: -74.962)
        XCTAssertFalse(OSMImporter.isForwardOfStart(point: behind, centerline: centerline))
    }

    func testPointPerpendicularToCenterline() {
        let centerline: CoordinatePath = [
            Coordinate(lat: 39.790, lon: -74.960),
            Coordinate(lat: 39.784, lon: -74.954)
        ]
        // Point slightly forward and perpendicular to the centerline direction
        let perp = Coordinate(lat: 39.7895, lon: -74.959)
        XCTAssertTrue(OSMImporter.isForwardOfStart(point: perp, centerline: centerline))
    }
}

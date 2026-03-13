import XCTest
@testable import CourseBuilder

final class FeatureTests: XCTestCase {
    func testPolygonFeatureCodableRoundTrip() throws {
        let feature = Feature(
            id: 1,
            type: .fairway,
            polygon: [
                Coordinate(latitude: 39.788, longitude: -74.958),
                Coordinate(latitude: 39.787, longitude: -74.957),
                Coordinate(latitude: 39.786, longitude: -74.956),
                Coordinate(latitude: 39.787, longitude: -74.959)
            ]
        )
        let data = try JSONEncoder().encode(feature)
        let decoded = try JSONDecoder().decode(Feature.self, from: data)
        XCTAssertEqual(feature, decoded)
        XCTAssertEqual(decoded.id, 1)
        XCTAssertEqual(decoded.type, .fairway)
        XCTAssertEqual(decoded.polygon.count, 4)
    }

    func testAllFeatureTypes() throws {
        let types: [FeatureType] = [.fairway, .green, .tee, .bunker, .water, .rough]
        for type in types {
            let feature = Feature(
                id: 1,
                type: type,
                polygon: [Coordinate(latitude: 0, longitude: 0)]
            )
            let data = try JSONEncoder().encode(feature)
            let decoded = try JSONDecoder().decode(Feature.self, from: data)
            XCTAssertEqual(decoded.type, type)
        }
    }

    func testFeatureJSONFormat() throws {
        let feature = Feature(
            id: 42,
            type: .bunker,
            polygon: [
                Coordinate(latitude: 39.0, longitude: -105.0),
                Coordinate(latitude: 39.1, longitude: -105.1)
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(feature)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["id"] as? Int, 42)
        XCTAssertEqual(json["type"] as? String, "bunker")
        let polygon = json["polygon"] as! [[Double]]
        XCTAssertEqual(polygon.count, 2)
        XCTAssertEqual(polygon[0][0], 39.0, accuracy: 0.001)
        XCTAssertEqual(polygon[0][1], -105.0, accuracy: 0.001)
    }
}

final class HoleTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let hole = Hole(
            number: 1,
            par: 4,
            maleHandicap: 13,
            yardages: ["Black": 401, "Gold": 378],
            featureIDs: [1, 2, 3],
            centerline: [
                Coordinate(latitude: 39.788, longitude: -74.958),
                Coordinate(latitude: 39.786, longitude: -74.956)
            ]
        )
        let data = try JSONEncoder().encode(hole)
        let decoded = try JSONDecoder().decode(Hole.self, from: data)
        XCTAssertEqual(hole, decoded)
        XCTAssertEqual(decoded.number, 1)
        XCTAssertEqual(decoded.par, 4)
        XCTAssertEqual(decoded.featureIDs, [1, 2, 3])
        XCTAssertEqual(decoded.centerline.count, 2)
    }

    func testRenumbered() {
        let hole = Hole(
            number: 7,
            par: 5,
            maleHandicap: 3,
            femaleHandicap: 5,
            yardages: ["Blue": 545],
            featureIDs: [10, 11],
            centerline: [Coordinate(latitude: 39.0, longitude: -105.0)]
        )
        let renumbered = hole.renumbered(to: 1)
        XCTAssertEqual(renumbered.number, 1)
        XCTAssertEqual(renumbered.par, 5)
        XCTAssertEqual(renumbered.maleHandicap, 3)
        XCTAssertEqual(renumbered.femaleHandicap, 5)
        XCTAssertEqual(renumbered.yardages["Blue"], 545)
        XCTAssertEqual(renumbered.featureIDs, [10, 11])
        XCTAssertEqual(renumbered.centerline.count, 1)
        XCTAssertNotEqual(renumbered.id, hole.id)
    }

    func testEmptyHole() {
        let hole = Hole(number: 5, par: 3, maleHandicap: 7)
        XCTAssertTrue(hole.yardages.isEmpty)
        XCTAssertTrue(hole.featureIDs.isEmpty)
        XCTAssertTrue(hole.centerline.isEmpty)
    }

    func testSplitIntoSubCourses18Holes() {
        let holes = (1...18).map { Hole(number: $0, par: $0 <= 9 ? 4 : 5) }
        let groups = Hole.splitIntoSubCourses(holes, names: ["Front", "Back"])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "Front")
        XCTAssertEqual(groups[0].holes.count, 9)
        XCTAssertEqual(groups[0].holes[0].number, 1)
        XCTAssertEqual(groups[0].holes[0].par, 4)
        XCTAssertEqual(groups[1].name, "Back")
        XCTAssertEqual(groups[1].holes.count, 9)
        XCTAssertEqual(groups[1].holes[0].number, 1)
        XCTAssertEqual(groups[1].holes[0].par, 5)
    }

    func testSplitIntoSubCourses9Holes() {
        let holes = (1...9).map { Hole(number: $0, par: 4) }
        let groups = Hole.splitIntoSubCourses(holes, names: ["Front", "Back"])
        // 9 holes should NOT split — single sub-course
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Front")
        XCTAssertEqual(groups[0].holes.count, 9)
    }

    func testSplitIntoSubCourses27HolesThreeNames() {
        let holes = (1...27).map { Hole(number: $0, par: 4) }
        let groups = Hole.splitIntoSubCourses(holes, names: ["Eldorado", "Vista", "Conquistador"])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].name, "Eldorado")
        XCTAssertEqual(groups[0].holes.count, 9)
        XCTAssertEqual(groups[1].name, "Vista")
        XCTAssertEqual(groups[1].holes.count, 9)
        XCTAssertEqual(groups[2].name, "Conquistador")
        XCTAssertEqual(groups[2].holes.count, 9)
        // All holes renumbered 1-9
        XCTAssertEqual(groups[2].holes[0].number, 1)
        XCTAssertEqual(groups[2].holes[8].number, 9)
    }
}

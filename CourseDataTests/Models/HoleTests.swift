import XCTest
@testable import CourseData

final class FeatureTests: XCTestCase {
    func testBunkerCodableRoundTrip() throws {
        let bunker = Feature(
            type: .bunker,
            front: Coordinate(latitude: 39.9387, longitude: -105.0249),
            back: Coordinate(latitude: 39.9388, longitude: -105.0248)
        )
        let data = try JSONEncoder().encode(bunker)
        let decoded = try JSONDecoder().decode(Feature.self, from: data)
        XCTAssertEqual(bunker, decoded)
        XCTAssertEqual(decoded.type, .bunker)
    }

    func testWaterCodableRoundTrip() throws {
        let water = Feature(
            type: .water,
            front: Coordinate(latitude: 39.9394, longitude: -105.0261),
            back: Coordinate(latitude: 39.9392, longitude: -105.0259)
        )
        let data = try JSONEncoder().encode(water)
        let decoded = try JSONDecoder().decode(Feature.self, from: data)
        XCTAssertEqual(water, decoded)
    }
}

final class HoleTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let hole = Hole(
            number: 1,
            par: 4,
            handicap: 13,
            yardages: ["Black": 401, "Gold": 378],
            tees: [
                "Black": Coordinate(latitude: 39.9401, longitude: -105.0271),
                "Gold": Coordinate(latitude: 39.9400, longitude: -105.0270)
            ],
            green: Green(
                front: Coordinate(latitude: 39.9386, longitude: -105.0246),
                middle: Coordinate(latitude: 39.9385, longitude: -105.0245),
                back: Coordinate(latitude: 39.9384, longitude: -105.0244)
            ),
            features: [
                Feature(
                    type: .bunker,
                    front: Coordinate(latitude: 39.9387, longitude: -105.0249),
                    back: Coordinate(latitude: 39.9388, longitude: -105.0248)
                )
            ]
        )
        let data = try JSONEncoder().encode(hole)
        let decoded = try JSONDecoder().decode(Hole.self, from: data)
        XCTAssertEqual(hole, decoded)
        XCTAssertEqual(decoded.number, 1)
        XCTAssertEqual(decoded.par, 4)
        XCTAssertEqual(decoded.tees.count, 2)
        XCTAssertEqual(decoded.green?.front.latitude, 39.9386)
        XCTAssertEqual(decoded.features.count, 1)
    }

    func testEmptyHole() {
        let hole = Hole(number: 5, par: 3, handicap: 7)
        XCTAssertTrue(hole.yardages.isEmpty)
        XCTAssertTrue(hole.tees.isEmpty)
        XCTAssertNil(hole.green)
        XCTAssertTrue(hole.features.isEmpty)
    }
}

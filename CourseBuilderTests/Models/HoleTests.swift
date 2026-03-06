import XCTest
@testable import CourseBuilder

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
            maleHandicap: 13,
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

    func testRenumbered() {
        let hole = Hole(
            number: 7,
            par: 5,
            maleHandicap: 3,
            femaleHandicap: 5,
            yardages: ["Blue": 545]
        )
        let renumbered = hole.renumbered(to: 1)
        XCTAssertEqual(renumbered.number, 1)
        XCTAssertEqual(renumbered.par, 5)
        XCTAssertEqual(renumbered.maleHandicap, 3)
        XCTAssertEqual(renumbered.femaleHandicap, 5)
        XCTAssertEqual(renumbered.yardages["Blue"], 545)
        XCTAssertNotEqual(renumbered.id, hole.id) // new identity
    }

    func testEmptyHole() {
        let hole = Hole(number: 5, par: 3, maleHandicap: 7)
        XCTAssertTrue(hole.yardages.isEmpty)
        XCTAssertTrue(hole.tees.isEmpty)
        XCTAssertNil(hole.green)
        XCTAssertTrue(hole.features.isEmpty)
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

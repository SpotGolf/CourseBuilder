import XCTest
@testable import CourseBuilder
import CourseDataSwift

final class TeeGuesserTests: XCTestCase {
    private let baseLat = 40.0
    private let baseLon = -105.0
    private let metersPerDegreeLatitude = 110_540.0
    private let metersPerYard = 0.9144

    /// A coordinate `north` meters north and `east` meters east of the base point.
    private func point(north: Double, east: Double = 0) -> Coordinate {
        let metersPerDegreeLongitude = 111_320.0 * cos(baseLat * .pi / 180)
        return Coordinate(
            latitude: baseLat + north / metersPerDegreeLatitude,
            longitude: baseLon + east / metersPerDegreeLongitude
        )
    }

    /// A square box from `southEdge` to `northEdge` meters north, centered on `east`.
    private func box(id: Int, type: FeatureType, southEdge: Double, northEdge: Double, east: Double = 0) -> Feature {
        let half = (northEdge - southEdge) / 2
        return Feature(id: id, type: type, polygon: [
            point(north: southEdge, east: east - half),
            point(north: southEdge, east: east + half),
            point(north: northEdge, east: east + half),
            point(north: northEdge, east: east - half)
        ])
    }

    private func yards(_ y: Double) -> Double { y * metersPerYard }

    /// A straight hole that plays north. Green center is 400 yards from the centerline start.
    private func straightHole(yardages: [String: Int], tees: [Feature]) -> (Hole, [Feature]) {
        let green = box(id: 1, type: .green, southEdge: yards(390), northEdge: yards(410))
        let hole = Hole(
            number: 1,
            par: 4,
            yardages: yardages,
            features: [1] + tees.map(\.id),
            centerline: [point(north: 0), point(north: yards(400))]
        )
        return (hole, [green] + tees)
    }

    func testTeeRangesMeasureFrontAndBackAlongCenterline() {
        let tee = box(id: 2, type: .tee, southEdge: yards(10), northEdge: yards(30))
        let (hole, features) = straightHole(yardages: ["Blue": 380], tees: [tee])

        let ranges = TeeGuesser.teeRanges(for: hole, features: features)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].featureID, 2)
        XCTAssertEqual(ranges[0].backYards, 390, accuracy: 0.5)
        XCTAssertEqual(ranges[0].frontYards, 370, accuracy: 0.5)
    }

    func testAssignsYardageToTeeBoxWhoseRangeContainsIt() {
        let back = box(id: 2, type: .tee, southEdge: 0, northEdge: yards(15))       // 385-400
        let middle = box(id: 3, type: .tee, southEdge: yards(40), northEdge: yards(55)) // 345-360
        let front = box(id: 4, type: .tee, southEdge: yards(90), northEdge: yards(100)) // 300-310
        let (hole, features) = straightHole(
            yardages: ["Black": 395, "Blue": 388, "White": 350, "Red": 305],
            tees: [front, back, middle]
        )

        let tees = TeeGuesser.guessTees(for: hole, features: features)

        XCTAssertEqual(tees, ["Black": 2, "Blue": 2, "White": 3, "Red": 4])
    }

    func testAssignsYardageToNearestRangeWhenNoneContainsIt() {
        let back = box(id: 2, type: .tee, southEdge: 0, northEdge: yards(15))       // 385-400
        let front = box(id: 3, type: .tee, southEdge: yards(90), northEdge: yards(100)) // 300-310
        let (hole, features) = straightHole(
            yardages: ["Blue": 370, "Red": 320],
            tees: [back, front]
        )

        let tees = TeeGuesser.guessTees(for: hole, features: features)

        XCTAssertEqual(tees, ["Blue": 2, "Red": 3])
    }

    func testTeeBoxBehindCenterlineStartGetsLongerDistance() {
        // Tee box sits 20-35 yards behind the start of the centerline.
        let tips = box(id: 2, type: .tee, southEdge: -yards(35), northEdge: -yards(20)) // 420-435
        let back = box(id: 3, type: .tee, southEdge: 0, northEdge: yards(15))           // 385-400
        let (hole, features) = straightHole(
            yardages: ["Tips": 428, "Blue": 392],
            tees: [tips, back]
        )

        let ranges = TeeGuesser.teeRanges(for: hole, features: features)
        let tipsRange = ranges.first { $0.featureID == 2 }!
        XCTAssertEqual(tipsRange.backYards, 435, accuracy: 0.5)
        XCTAssertEqual(tipsRange.frontYards, 420, accuracy: 0.5)

        let tees = TeeGuesser.guessTees(for: hole, features: features)
        XCTAssertEqual(tees, ["Tips": 2, "Blue": 3])
    }

    func testDoglegUsesDistanceAlongCenterline() {
        // Plays 200 yards north, then 200 yards east. Straight-line distance from the tee
        // to the green is about 283 yards, but along the centerline it is 400.
        let green = box(id: 1, type: .green, southEdge: yards(190), northEdge: yards(210), east: yards(200))
        let tee = box(id: 2, type: .tee, southEdge: 0, northEdge: yards(10))
        let hole = Hole(
            number: 1,
            par: 4,
            yardages: ["Blue": 395, "Red": 285],
            features: [1, 2],
            centerline: [point(north: 0), point(north: yards(200)), point(north: yards(200), east: yards(200))]
        )

        let ranges = TeeGuesser.teeRanges(for: hole, features: [green, tee])

        XCTAssertEqual(ranges[0].backYards, 400, accuracy: 1)
        XCTAssertEqual(ranges[0].frontYards, 390, accuracy: 1)
    }

    func testReturnsEmptyWithoutYardagesCenterlineOrTees() {
        let tee = box(id: 2, type: .tee, southEdge: 0, northEdge: yards(15))

        let (noYardages, features) = straightHole(yardages: [:], tees: [tee])
        XCTAssertTrue(TeeGuesser.guessTees(for: noYardages, features: features).isEmpty)

        var noCenterline = straightHole(yardages: ["Blue": 390], tees: [tee]).0
        noCenterline.centerline = [point(north: 0)]
        XCTAssertTrue(TeeGuesser.guessTees(for: noCenterline, features: features).isEmpty)

        let (noTees, greenOnly) = straightHole(yardages: ["Blue": 390], tees: [])
        XCTAssertTrue(TeeGuesser.guessTees(for: noTees, features: greenOnly).isEmpty)
    }

    func testIgnoresTeeBoxesNotOnHole() {
        let onHole = box(id: 2, type: .tee, southEdge: 0, northEdge: yards(15))
        let offHole = box(id: 9, type: .tee, southEdge: yards(90), northEdge: yards(100))
        var (hole, features) = straightHole(yardages: ["Red": 305], tees: [onHole])
        features.append(offHole)
        hole.features = [1, 2]

        XCTAssertEqual(TeeGuesser.guessTees(for: hole, features: features), ["Red": 2])
    }
}

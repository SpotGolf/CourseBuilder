import XCTest
@testable import CourseBuilder
import CourseDataSwift

final class FeatureSorterTests: XCTestCase {
    private let baseLat = 40.0
    private let baseLon = -105.0

    /// A coordinate `north` meters north and `east` meters east of the base point.
    private func point(north: Double, east: Double = 0) -> Coordinate {
        let metersPerDegreeLongitude = 111_320.0 * cos(baseLat * .pi / 180)
        return Coordinate(
            lat: baseLat + north / 110_540.0,
            lon: baseLon + east / metersPerDegreeLongitude
        )
    }

    /// A 10 m square centered `north` meters north and `east` meters east of the base point.
    private func square(id: Int, type: FeatureType, north: Double, east: Double = 0) -> Feature {
        Feature(id: id, type: type, polygon: [
            point(north: north - 5, east: east - 5),
            point(north: north - 5, east: east + 5),
            point(north: north + 5, east: east + 5),
            point(north: north + 5, east: east - 5)
        ])
    }

    func testFarthestFromGreenFirstAndGreenLast() {
        let green = square(id: 1, type: .green, north: 400)
        let tee = square(id: 2, type: .tee, north: 0)
        let fairway = square(id: 3, type: .fairway, north: 200)
        let bunker = square(id: 4, type: .bunker, north: 370, east: 20)
        let hole = Hole(number: 1, par: 4, yardages: [:], features: [1, 2, 3, 4], centerline: [])

        let sorted = FeatureSorter.sortedByDistanceFromGreen([green, bunker, fairway, tee], hole: hole)

        XCTAssertEqual(sorted.map(\.id), [2, 3, 4, 1])
    }

    func testTiesKeepAscendingIDOrder() {
        let green = square(id: 1, type: .green, north: 100)
        let left = square(id: 7, type: .bunker, north: 100, east: -30)
        let right = square(id: 3, type: .bunker, north: 100, east: 30)
        let hole = Hole(number: 1, par: 3, yardages: [:], features: [1, 3, 7], centerline: [])

        let sorted = FeatureSorter.sortedByDistanceFromGreen([left, green, right], hole: hole)

        XCTAssertEqual(sorted.map(\.id), [3, 7, 1])
    }

    func testUsesCenterlineEndWhenHoleHasNoGreen() {
        let tee = square(id: 2, type: .tee, north: 0)
        let fairway = square(id: 3, type: .fairway, north: 200)
        let hole = Hole(
            number: 1, par: 4, yardages: [:], features: [2, 3],
            centerline: [point(north: 0), point(north: 400)]
        )

        let sorted = FeatureSorter.sortedByDistanceFromGreen([fairway, tee], hole: hole)

        XCTAssertEqual(sorted.map(\.id), [2, 3])
    }

    func testUnchangedWithoutGreenOrCenterline() {
        let tee = square(id: 2, type: .tee, north: 0)
        let fairway = square(id: 3, type: .fairway, north: 200)
        let hole = Hole(number: 1, par: 4, yardages: [:], features: [2, 3], centerline: [])

        let sorted = FeatureSorter.sortedByDistanceFromGreen([fairway, tee], hole: hole)

        XCTAssertEqual(sorted.map(\.id), [3, 2])
    }
}

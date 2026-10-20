import CoreGraphics
import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct AutoPolygonSessionTests {
    typealias S = SyntheticImagery

    /// Sand half-disk A (west) touching grey half-disk B (east), radius 6 m, in grass.
    private let twoColors = S.patch { east, north in
        guard hypot(east, north) <= 6 else { return S.grass }
        return east < 0 ? S.sand : S.grey
    }
    private let halfDiskArea = Double.pi * 36 / 2
    private let pointA = S.coordinate(east: -3, north: 0)
    private let pointB = S.coordinate(east: 3, north: 0)

    @Test func clickFindsOnlyMatchingColor() throws {
        var session = AutoPolygonSession(mode: .create(.bunker), patch: twoColors, operations: [.add(pointA)])
        session.recompute()
        let result = try #require(session.result)
        expectArea(result.polygon, near: halfDiskArea)
    }

    @Test func addThenRemove() throws {
        var session = AutoPolygonSession(mode: .create(.bunker), patch: twoColors, operations: [.add(pointA), .add(pointB)])
        session.recompute()
        expectArea(try #require(session.result).polygon, near: 2 * halfDiskArea)

        session.operations.append(.remove(pointB))
        session.recompute()
        expectArea(try #require(session.result).polygon, near: halfDiskArea)
    }

    @Test func raisingToleranceJoinsCloseColors() throws {
        var session = AutoPolygonSession(mode: .create(.bunker), patch: twoColors, operations: [.add(pointA)])
        session.tolerance = 7
        session.recompute()
        expectArea(try #require(session.result).polygon, near: 2 * halfDiskArea)
    }

    @Test func fitMovesShiftedPolygonOntoBunker() throws {
        let patch = S.patch { east, north in hypot(east, north) <= 5 ? S.sand : S.grass }
        let oldPolygon = S.circle(east: 2, north: 0, radius: 5)
        var session = AutoPolygonSession(mode: .fit(featureID: 1, type: .bunker, oldPolygon: oldPolygon), patch: patch)
        session.recompute()
        let result = try #require(session.result)
        let offset = S.centroidOffset(result.polygon)
        #expect(hypot(offset.east, offset.north) < 0.5)
        expectArea(result.polygon, near: .pi * 25)
        #expect(!result.areaDiffersFromOriginal)
    }

    @Test func fitFlagsLargeAreaChange() throws {
        let patch = S.patch { east, north in hypot(east, north) <= 3 ? S.sand : S.grass }
        let oldPolygon = S.circle(east: 0, north: 0, radius: 6)
        var session = AutoPolygonSession(mode: .fit(featureID: 1, type: .bunker, oldPolygon: oldPolygon), patch: patch)
        session.recompute()
        #expect(try #require(session.result).areaDiffersFromOriginal)
    }

    /// A 30 m × 80 m fairway in rough, with the measured colors.
    private let fairwayInRough = S.patch { east, north in
        abs(east) <= 15 && abs(north) <= 40 ? S.realFairway : S.realRough
    }

    @Test func autoFairwaySplitsFromRough() throws {
        var session = AutoPolygonSession(mode: .create(.fairway), patch: fairwayInRough, operations: [.add(S.center)])
        session.recompute()
        expectArea(try #require(session.result).polygon, near: 30 * 80)
    }

    @Test func fitFairwayMovesOffsetOutlineOntoFairway() throws {
        let east = 4.0
        let oldPolygon = [
            S.coordinate(east: -15 + east, north: -40), S.coordinate(east: 15 + east, north: -40),
            S.coordinate(east: 15 + east, north: 40), S.coordinate(east: -15 + east, north: 40),
        ]
        var session = AutoPolygonSession(mode: .fit(featureID: 1, type: .fairway, oldPolygon: oldPolygon), patch: fairwayInRough)
        session.recompute()
        let result = try #require(session.result)
        expectArea(result.polygon, near: 30 * 80)
        let offset = S.centroidOffset(result.polygon)
        #expect(hypot(offset.east, offset.north) < 1)
    }

    @Test func fitToleranceKeepsMoreOrFewerPixels() throws {
        let oldPolygon = S.circle(east: 0, north: 0, radius: 14)
        func area(_ tolerance: Double) throws -> Double {
            var session = AutoPolygonSession(mode: .fit(featureID: 1, type: .fairway, oldPolygon: oldPolygon), patch: fairwayInRough)
            session.tolerance = tolerance
            session.recompute()
            return S.area(try #require(session.result).polygon)
        }
        #expect(try area(8) >= area(2))
    }

    @Test func requiredBoxCoversSearchRadius() throws {
        let box = try #require(AutoPolygonSession.requiredBox(mode: .create(.bunker), operations: [.add(S.center)]))
        let expected = OverpassAPIClient.BoundingBox(around: S.center, radiusMeters: 40)
        #expect(box == expected)
        #expect(AutoPolygonSession.requiredBox(mode: .create(.bunker), operations: []) == nil)
    }

    private func expectArea(_ polygon: [Coordinate], near expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let area = S.area(polygon)
        #expect(abs(area - expected) / expected < 0.08, "area \(area) m², expected \(expected) m²", sourceLocation: sourceLocation)
    }
}

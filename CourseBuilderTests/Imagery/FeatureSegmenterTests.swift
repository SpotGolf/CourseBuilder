import CoreGraphics
import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct FeatureSegmenterTests {
    typealias S = SyntheticImagery

    @Test func sandDiskInGrass() throws {
        let patch = S.patch { east, north in hypot(east, north) <= 5 ? S.sand : S.grass }
        let result = try #require(detect(.bunker, in: patch, at: S.center))
        expectArea(result.polygon, near: .pi * 25)
        #expect(!result.exceedsSafetyLimit)
    }

    @Test func waterInGrass() throws {
        let patch = S.patch { east, north in hypot(east - 3, north) <= 15 ? S.water : S.grass }
        let result = try #require(detect(.water, in: patch, at: S.coordinate(east: 3, north: 0)))
        expectArea(result.polygon, near: .pi * 225)
    }

    @Test func fairwayStripStopsAtRough() throws {
        let patch = S.patch { east, _ in abs(east) <= 15 ? S.fairway : S.rough }
        let result = try #require(detect(.fairway, in: patch, at: S.center))
        let patchHeightMeters = Double(patch.height) * S.metersPerPixel
        expectArea(result.polygon, near: 30 * patchHeightMeters)
    }

    @Test func typeRuleRejectsGrassForBunker() {
        let patch = S.patch { _, _ in S.grass }
        #expect(detect(.bunker, in: patch, at: S.center) == nil)
    }

    @Test func flatSeedUsesMinimumSpread() throws {
        let patch = S.patch(size: 32) { _, _ in S.sand }
        let values = PixelValues(patch: patch, window: PixelWindow(x: 0, y: 0, width: 32, height: 32))
        let statistics = try #require(SeedStatistics(values: values, pixels: Array(0..<64)))
        #expect(statistics.spread == SeedStatistics.minimumSpread)
    }

    @Test func filledHolesAndClosing() {
        var ring = BinaryMask(width: 10, height: 10)
        for y in 2..<8 {
            for x in 2..<8 where x == 2 || x == 7 || y == 2 || y == 7 {
                ring[x, y] = true
            }
        }
        #expect(ring.filledHoles().count == 36)

        var split = BinaryMask(width: 12, height: 5)
        for y in 0..<5 {
            for x in 1..<11 where x != 6 {
                split[x, y] = true
            }
        }
        #expect(split.closed(by: 1)[6, 2])
    }

    @Test func labOfWhiteAndBlack() {
        let white = PixelValues.lab(r: 255, g: 255, b: 255)
        #expect(abs(white.l - 100) < 0.5)
        #expect(abs(white.a) < 0.5 && abs(white.b) < 0.5)
        #expect(abs(PixelValues.lab(r: 0, g: 0, b: 0).l) < 0.5)
    }

    // MARK: - Helpers

    private func detect(_ type: FeatureType, in patch: ImagePatch, at coordinate: Coordinate) -> AutoPolygonSession.Result? {
        var session = AutoPolygonSession(mode: .create(type), patch: patch, operations: [.add(coordinate)])
        session.recompute()
        return session.result
    }

    private func expectArea(_ polygon: [Coordinate], near expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let area = S.area(polygon)
        #expect(abs(area - expected) / expected < 0.05, "area \(area) m², expected \(expected) m²", sourceLocation: sourceLocation)
    }
}

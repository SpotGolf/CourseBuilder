import CoreGraphics
import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct OutlineTracerTests {
    /// Meters per pixel at 40° N, zoom 19.
    let mpp = 0.2287

    @Test func squareTracesEveryCorner() {
        let mask = makeMask(width: 20, height: 20) { x, y in (5..<15).contains(x) && (5..<15).contains(y) }
        let ring = OutlineTracer.traceBoundary(mask)
        #expect(ring.count == 40)
        #expect(ring.first == CGPoint(x: 5, y: 5))
        #expect(polygonArea(ring) == 100)
    }

    @Test func squareReducesToFourPoints() {
        let mask = makeMask(width: 60, height: 60) { x, y in (10..<50).contains(x) && (10..<50).contains(y) }
        let reduced = OutlineTracer.reducePoints(OutlineTracer.traceBoundary(mask), type: .bunker, metersPerPixel: mpp)
        #expect(reduced.points.count == 4)
        #expect(!reduced.exceedsSafetyLimit)
    }

    @Test func lShapeReducesToSixPoints() {
        let mask = makeMask(width: 80, height: 80) { x, y in
            (10..<70).contains(x) && (10..<70).contains(y) && !(x >= 40 && y < 40)
        }
        let ring = OutlineTracer.traceBoundary(mask)
        #expect(polygonArea(ring) == Double(mask.count))
        let reduced = OutlineTracer.reducePoints(ring, type: .bunker, metersPerPixel: mpp)
        #expect(reduced.points.count == 6)
    }

    @Test func simplifyDropsCollinearPoints() {
        let ring = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0),
                    CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        #expect(OutlineTracer.simplify(ring, epsilon: 0.5).count == 4)
    }

    @Test func circleStaysWithinErrorLimitAndSpacing() {
        let radius = 60.0
        let mask = makeMask(width: 140, height: 140) { x, y in
            hypot(Double(x) + 0.5 - 70, Double(y) + 0.5 - 70) <= radius
        }
        let ring = OutlineTracer.traceBoundary(mask)
        let reduced = OutlineTracer.reducePoints(ring, type: .green, metersPerPixel: mpp)
        let profile = FeatureType.green.segmentationProfile
        let epsilon = max(profile.errorLimitMeters / mpp, 0.6)

        // Every point of the smoothed edge is within the error limit of the reduced outline.
        let midpoints = ring.indices.map { i -> CGPoint in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let smoothed = OutlineTracer.smooth(midpoints, radius: max(1, Int((profile.errorLimitMeters / mpp).rounded())))
        for point in smoothed {
            #expect(distanceToRing(point, reduced.points) <= epsilon + 1e-9)
        }
        // Every pair of neighbors is at least the minimum spacing apart.
        let spacing = profile.minSpacingMeters / mpp
        for i in reduced.points.indices {
            let a = reduced.points[i], b = reduced.points[(i + 1) % reduced.points.count]
            #expect(hypot(Double(a.x - b.x), Double(a.y - b.y)) >= spacing - 1e-9)
        }
        #expect(reduced.points.count < 40)
    }

    @Test func fiveLobeBunkerKeepsItsLobes() {
        // Five 2.5 m lobes around a 3 m center, about 60 m around the outside.
        let r = 2.5 / mpp, ring = 3.5 / mpp, core = 3 / mpp, c = 60.0
        let lobes = (0..<5).map { i -> CGPoint in
            let angle = Double(i) / 5 * 2 * .pi
            return CGPoint(x: c + ring * cos(angle), y: c + ring * sin(angle))
        }
        let mask = makeMask(width: 120, height: 120) { x, y in
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            if hypot(px - c, py - c) <= core { return true }
            return lobes.contains { hypot(px - Double($0.x), py - Double($0.y)) <= r }
        }
        let reduced = OutlineTracer.reducePoints(OutlineTracer.traceBoundary(mask), type: .bunker, metersPerPixel: mpp)
        #expect(reduced.points.count > 16)
        #expect(reduced.points.count <= FeatureType.bunker.segmentationProfile.safetyLimit)
        let areaError = abs(polygonArea(reduced.points) - Double(mask.count)) / Double(mask.count)
        #expect(areaError < 0.05)
        // Each lobe's outer tip is still on the outline.
        for lobe in lobes {
            let dx = Double(lobe.x) - c, dy = Double(lobe.y) - c
            let length = hypot(dx, dy)
            let tip = CGPoint(x: Double(lobe.x) + dx / length * r, y: Double(lobe.y) + dy / length * r)
            #expect(distanceToRing(tip, reduced.points) < 0.5 / mpp)
        }
    }

    @Test func safetyLimitFlagsWithoutChangingShape() {
        // A 60-point star needs far more than a tee's 30-point limit.
        let c = 150.0
        let mask = makeMask(width: 300, height: 300) { x, y in
            let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
            let angle = atan2(dy, dx)
            let radius = 100 + 40 * (0.5 + 0.5 * cos(angle * 60))
            return hypot(dx, dy) <= radius
        }
        let ring = OutlineTracer.traceBoundary(mask)
        let reduced = OutlineTracer.reducePoints(ring, type: .tee, metersPerPixel: mpp)
        #expect(reduced.exceedsSafetyLimit)
        #expect(reduced.points.count > 60)
    }

    // MARK: - Helpers

    private func makeMask(width: Int, height: Int, _ isOn: (Int, Int) -> Bool) -> BinaryMask {
        var mask = BinaryMask(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width where isOn(x, y) {
                mask[x, y] = true
            }
        }
        return mask
    }

    private func polygonArea(_ points: [CGPoint]) -> Double {
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    private func distanceToRing(_ p: CGPoint, _ ring: [CGPoint]) -> Double {
        ring.indices.map { OutlineTracer.distance(p, toSegment: ring[$0], ring[($0 + 1) % ring.count]) }.min() ?? .infinity
    }
}

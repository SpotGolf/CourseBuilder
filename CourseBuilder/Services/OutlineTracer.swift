import CoreGraphics
import Foundation
import CourseDataSwift

/// An outline after point reduction, in pixel units.
struct ReducedOutline: Equatable {
    let points: [CGPoint]
    /// True when the outline has more points than the type's safety limit. The shape is not
    /// changed; the user decides whether to keep it.
    let exceedsSafetyLimit: Bool
}

enum OutlineTracer {
    /// Traces the outer edge of the mask's 4-connected piece that holds its first on pixel.
    /// Returns every pixel corner along the edge in order, as a closed ring (the first point
    /// is not repeated). Corner (x, y) is the top-left corner of pixel (x, y).
    static func traceBoundary(_ mask: BinaryMask) -> [CGPoint] {
        guard let start = mask.bits.firstIndex(of: true) else { return [] }
        let startX = start % mask.width, startY = start / mask.width
        var x = startX, y = startY
        // Heading east along the top edge of the start pixel, with the inside on the right.
        var dx = 1, dy = 0
        var corners: [CGPoint] = []
        let maxSteps = 4 * (mask.width + 1) * (mask.height + 1)

        repeat {
            corners.append(CGPoint(x: x, y: y))
            let rx = -dy, ry = dx // right turn
            let lx = dy, ly = -dx // left turn
            // The two pixels ahead of this corner, on the right and left of the heading.
            let aheadRight = mask[x + (dx + rx == 1 ? 0 : -1), y + (dy + ry == 1 ? 0 : -1)]
            let aheadLeft = mask[x + (dx + lx == 1 ? 0 : -1), y + (dy + ly == 1 ? 0 : -1)]
            if aheadRight && aheadLeft {
                (dx, dy) = (lx, ly)
            } else if !aheadRight {
                (dx, dy) = (rx, ry)
            }
            x += dx
            y += dy
        } while !(x == startX && y == startY) && corners.count < maxSteps

        return corners
    }

    /// Reduces a traced ring to the points the shape needs, using the type's limits:
    /// 1. Error limit — simplify (Douglas–Peucker) so the outline stays within the limit of the edge.
    /// 2. Minimum spacing — drop points closer than the spacing to the previous kept point.
    /// 3. Safety limit — flag the result when it still has too many points.
    static func reducePoints(_ ring: [CGPoint], type: FeatureType, metersPerPixel: Double) -> ReducedOutline {
        let profile = type.segmentationProfile
        guard ring.count >= 3, metersPerPixel > 0 else {
            return ReducedOutline(points: ring, exceedsSafetyLimit: false)
        }

        // Midpoints of the unit steps turn pixel stair steps into straight runs.
        let midpoints = ring.indices.map { i -> CGPoint in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        // Average over about twice the error limit of edge to remove pixel noise before simplifying.
        let smoothed = smooth(midpoints, radius: max(1, Int((profile.errorLimitMeters / metersPerPixel).rounded())))
        // The pixel grid itself is only accurate to about half a pixel.
        let epsilon = max(profile.errorLimitMeters / metersPerPixel, 0.6)
        var points = simplify(smoothed, epsilon: epsilon)
        points = enforceSpacing(points, minimumSpacing: profile.minSpacingMeters / metersPerPixel)
        return ReducedOutline(points: points, exceedsSafetyLimit: points.count > profile.safetyLimit)
    }

    /// Moving average over `radius` points on each side, on a closed ring.
    static func smooth(_ ring: [CGPoint], radius: Int) -> [CGPoint] {
        guard radius > 0, ring.count > 2 * radius + 2 else { return ring }
        let n = ring.count
        let width = CGFloat(2 * radius + 1)
        return (0..<n).map { i in
            var x: CGFloat = 0, y: CGFloat = 0
            for k in -radius...radius {
                let p = ring[(i + k + n) % n]
                x += p.x
                y += p.y
            }
            return CGPoint(x: x / width, y: y / width)
        }
    }

    /// Douglas–Peucker on a closed ring.
    static func simplify(_ ring: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard ring.count > 3 else { return ring }
        // Split the ring at the point farthest from the first one.
        var farthest = 0
        var farthestDistance = 0.0
        for i in ring.indices {
            let d = hypot(Double(ring[i].x - ring[0].x), Double(ring[i].y - ring[0].y))
            if d > farthestDistance {
                farthestDistance = d
                farthest = i
            }
        }
        guard farthest > 0 else { return Array(ring.prefix(1)) }
        let first = simplifyChain(Array(ring[0...farthest]), epsilon: epsilon)
        let second = simplifyChain(Array(ring[farthest...]) + [ring[0]], epsilon: epsilon)
        // Both chains include the split points; drop the duplicates.
        return Array(first.dropLast()) + Array(second.dropLast())
    }

    /// Douglas–Peucker on an open chain. Keeps both ends.
    static func simplifyChain(_ chain: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard chain.count > 2 else { return chain }
        var keep = Array(repeating: false, count: chain.count)
        keep[0] = true
        keep[chain.count - 1] = true
        var stack = [(0, chain.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDistance = 0.0
            var maxIndex = start
            for i in (start + 1)..<end {
                let d = distance(chain[i], toSegment: chain[start], chain[end])
                if d > maxDistance {
                    maxDistance = d
                    maxIndex = i
                }
            }
            if maxDistance > epsilon {
                keep[maxIndex] = true
                stack.append((start, maxIndex))
                stack.append((maxIndex, end))
            }
        }
        return chain.indices.filter { keep[$0] }.map { chain[$0] }
    }

    /// Drops points closer than `minimumSpacing` to the previous kept point. Never returns
    /// fewer than 3 points; if spacing would, the input is returned.
    static func enforceSpacing(_ ring: [CGPoint], minimumSpacing: Double) -> [CGPoint] {
        guard ring.count > 3, minimumSpacing > 0 else { return ring }
        var kept = [ring[0]]
        for point in ring.dropFirst() {
            let last = kept[kept.count - 1]
            if hypot(Double(point.x - last.x), Double(point.y - last.y)) >= minimumSpacing {
                kept.append(point)
            }
        }
        if kept.count > 3,
           hypot(Double(kept[kept.count - 1].x - kept[0].x), Double(kept[kept.count - 1].y - kept[0].y)) < minimumSpacing {
            kept.removeLast()
        }
        return kept.count >= 3 ? kept : ring
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(Double(p.x - a.x), Double(p.y - a.y)) }
        let t = max(0, min(1, (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / lengthSquared))
        return hypot(Double(p.x) - (Double(a.x) + t * dx), Double(p.y) - (Double(a.y) + t * dy))
    }
}

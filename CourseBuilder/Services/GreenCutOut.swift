import Foundation
import CourseDataSwift

/// Cuts a green out of a fairway that is drawn over it and shares part of its outline, such as an
/// apron that wraps the front of a green whose back edge is the fairway's edge.
///
/// A multipolygon does not fit this case, because OSM does not allow an inner ring to run along
/// the outer ring. The fairway minus the green is still one outline, so the fairway is reshaped
/// instead.
enum GreenCutOut {
    /// The greens that can be cut out of the fairway.
    static func greens(toCutOutOf fairway: Feature, course: Course) -> [Feature] {
        guard fairway.type == .fairway else { return [] }
        return course.features.filter { green in
            green.type == .green && green.id != fairway.id
                && cutOut(Array(green.polygon), from: Array(fairway.polygon)) != nil
        }
    }

    /// The fairway's outline with the green cut out, or nil when the green does not share one
    /// unbroken stretch of the fairway's outline with the rest of it inside the fairway.
    ///
    /// The result keeps the fairway's points off the shared stretch, then follows the green's
    /// points that are inside the fairway back to the start. Points are reused as they are, so
    /// the published way shares the green's nodes. A closed fairway gives a closed result.
    static func cutOut(_ green: [Coordinate], from fairway: [Coordinate]) -> [Coordinate]? {
        let outer = openRing(fairway)
        let inner = openRing(green)
        guard outer.count >= 3, inner.count >= 3 else { return nil }

        // The green point at each fairway point, for fairway points on the green's outline.
        let matches: [Int?] = outer.map { point in inner.firstIndex { same($0, point) } }
        let sharedCount = matches.compactMap(\.self).count
        guard sharedCount >= 2, sharedCount < outer.count else { return nil }

        // The shared points must be one unbroken stretch of the fairway's outline.
        let starts = outer.indices.filter { matches[$0] != nil && matches[(($0 - 1) + outer.count) % outer.count] == nil }
        guard starts.count == 1 else { return nil }
        let start = starts[0]
        let end = (start + sharedCount - 1) % outer.count
        let stretch = (0..<sharedCount).map { matches[(start + $0) % outer.count]! }

        // The direction the green's outline runs along the stretch. The green may have extra
        // points on it, so the steps only need to move the same way.
        guard let step = [1, -1].first(where: { step in
            let offsets = stretch.map { (($0 - stretch[0]) * step + inner.count) % inner.count }
            return zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 }
        }) else { return nil }

        // The rest of the green's outline, from the end of the stretch back to its start. It
        // must have points, and they must be inside the fairway, or the green is outside it.
        var rest: [Coordinate] = []
        var index = (stretch[0] - step + inner.count) % inner.count
        while index != stretch[sharedCount - 1] {
            rest.append(inner[index])
            index = (index - step + inner.count) % inner.count
        }
        guard !rest.isEmpty, rest.allSatisfy({ PolygonGeometry.contains($0, in: outer) }) else { return nil }

        var result: [Coordinate] = []
        index = end
        while index != start {
            result.append(outer[index])
            index = (index + 1) % outer.count
        }
        result.append(outer[start])
        result.append(contentsOf: rest)
        if fairway.count > outer.count {
            result.append(result[0])
        }
        return result
    }

    /// The points without a last point that repeats the first.
    private static func openRing(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 1, let first = points.first, let last = points.last, same(first, last) else { return points }
        return Array(points.dropLast())
    }

    private static func same(_ a: Coordinate, _ b: Coordinate) -> Bool {
        OSMChangeDetector.distanceMeters(a, b) <= OSMChangeDetector.samePointMeters
    }
}

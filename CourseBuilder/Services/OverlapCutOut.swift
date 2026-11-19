import Foundation
import CourseDataSwift

/// Cuts a feature out of a fairway or green that overlaps it, such as a bunker beside a green
/// that is drawn partly over the fairway or the green instead of next to it.
///
/// The fairway or green is reshaped to follow the feature's edge where they overlap, so the two
/// end up side by side and the published way shares the feature's nodes. The feature is not
/// changed.
///
/// The shape with the edge that is harder to see in imagery gives way. A fairway gives way to
/// greens, tees, bunkers, and water. A green gives way to bunkers and water.
///
/// ``GreenCutOut`` covers the other case, where the two already share part of their outlines.
enum OverlapCutOut {
    /// How far outside the other outline a point can be and still be part of the stretch where
    /// the two outlines meet. Two edges drawn along the same line wander about this far apart.
    static let nearMeters = 3.0

    /// The feature types that are cut out of a feature of the given type. Empty for types that
    /// never give way.
    static func typesCutOut(of type: FeatureType) -> Set<FeatureType> {
        switch type {
        case .fairway: [.green, .tee, .bunker, .water]
        case .green: [.bunker, .water]
        case .tee, .bunker, .water, .centerline: []
        }
    }

    /// The features that overlap the fairway or green and can be cut out of it.
    static func features(toCutOutOf fairway: Feature, course: Course) -> [Feature] {
        let types = typesCutOut(of: fairway.type)
        guard !types.isEmpty else { return [] }
        let outline = Array(fairway.polygon)
        return course.features.filter { feature in
            feature.id != fairway.id && types.contains(feature.type)
                && cutOut(Array(feature.polygon), from: outline) != nil
        }
    }

    /// The outline of the fairway or green with every overlapping feature cut out, or nil when
    /// none overlaps.
    static func cutOutAll(from fairway: Feature, course: Course) -> [Coordinate]? {
        var outline = Array(fairway.polygon)
        var changed = false
        for feature in features(toCutOutOf: fairway, course: course) {
            guard let result = cutOut(Array(feature.polygon), from: outline) else { continue }
            outline = result
            changed = true
        }
        return changed ? outline : nil
    }

    /// The outline of the fairway, or of a green passed in its place, with the shape cut out. Nil
    /// when the shape does not overlap the outline's edge.
    ///
    /// The two outlines can cross any number of times along the stretch where they meet, and can
    /// already share some points there. The result keeps the fairway's points away from that
    /// stretch, then follows the shape's points along it. The shape's points are reused as they
    /// are, so the published way shares the shape's nodes. A closed fairway gives a closed result.
    static func cutOut(_ shape: [Coordinate], from fairway: [Coordinate]) -> [Coordinate]? {
        let outer = GreenCutOut.openRing(fairway)
        let inner = GreenCutOut.openRing(shape)
        guard outer.count >= 3, inner.count >= 3 else { return nil }

        // The places on each outline where the two meet. Point `i` is place `2 * i`, and the
        // edge after it is place `2 * i + 1`.
        var outerPlaces: Set<Int> = []
        var innerPlaces: Set<Int> = []
        var overlaps = false
        for i in outer.indices {
            for j in inner.indices where OSMMultipolygon.crosses(
                outer[i], outer[(i + 1) % outer.count], inner[j], inner[(j + 1) % inner.count]
            ) {
                outerPlaces.insert(2 * i + 1)
                innerPlaces.insert(2 * j + 1)
                overlaps = true
            }
        }
        for (i, point) in outer.enumerated() {
            if let j = inner.firstIndex(where: { GreenCutOut.same($0, point) }) {
                outerPlaces.insert(2 * i)
                innerPlaces.insert(2 * j)
            } else if PolygonGeometry.contains(point, in: inner) {
                outerPlaces.insert(2 * i)
                overlaps = true
            }
        }
        for (j, point) in inner.enumerated() where PolygonGeometry.contains(point, in: outer) {
            innerPlaces.insert(2 * j)
        }
        // Outlines that only share points, or do not touch, are left alone.
        guard overlaps else { return nil }

        // The fairway's points away from the shape are kept. The shape's points away from the
        // fairway are dropped, which leaves its points along the stretch where the two meet.
        guard let keep = longestClearRun(between: outerPlaces, count: outer.count),
              let away = longestClearRun(between: innerPlaces, count: inner.count),
              away.length < inner.count else { return nil }
        let kept = (0..<keep.length).map { outer[(keep.start + $0) % outer.count] }
        var along = (0..<(inner.count - away.length)).map { inner[(away.start + away.length + $0) % inner.count] }

        // Join the shape's points on in the direction that does not cross over itself, which is
        // the shorter of the two ways to connect the ends.
        if let last = kept.last, let start = kept.first, let head = along.first, let tail = along.last {
            let forward = OSMChangeDetector.distanceMeters(last, head) + OSMChangeDetector.distanceMeters(tail, start)
            let backward = OSMChangeDetector.distanceMeters(last, tail) + OSMChangeDetector.distanceMeters(head, start)
            if backward < forward { along.reverse() }
        }

        // The fix only moves the fairway's edge where it meets the shape. A dropped fairway point
        // or a shape point on the new edge that is far from the other outline means the two meet
        // in more than one stretch, such as a strip across the fairway.
        let dropped = outer.filter { point in !kept.contains { $0 == point } }
        guard dropped.allSatisfy({ isNear($0, inner) }), along.allSatisfy({ isNear($0, outer) }) else { return nil }

        var result = kept + along
        guard result.count >= 3 else { return nil }
        if fairway.count > outer.count {
            result.append(result[0])
        }
        return result
    }

    /// Whether the point is inside the outline or within ``nearMeters`` of its edge.
    private static func isNear(_ point: Coordinate, _ outline: [Coordinate]) -> Bool {
        if PolygonGeometry.contains(point, in: outline) { return true }
        // Longitude is scaled so that both directions are the same length on the ground.
        let scale = cos(point.lat * .pi / 180)
        return outline.indices.contains { index in
            let start = outline[index], end = outline[(index + 1) % outline.count]
            let dx = (end.lon - start.lon) * scale, dy = end.lat - start.lat
            let lengthSquared = dx * dx + dy * dy
            let along = lengthSquared == 0 ? 0
                : max(0, min(1, (((point.lon - start.lon) * scale) * dx + (point.lat - start.lat) * dy) / lengthSquared))
            let nearest = Coordinate(lat: start.lat + along * (end.lat - start.lat), lon: start.lon + along * (end.lon - start.lon))
            return OSMChangeDetector.distanceMeters(nearest, point) <= nearMeters
        }
    }

    /// The longest run of points with none of the places on or between them, as its first point
    /// and its length. Nil when every point is next to a place.
    private static func longestClearRun(between places: Set<Int>, count: Int) -> (start: Int, length: Int)? {
        let sorted = places.sorted()
        var best: (start: Int, length: Int)?
        for (index, place) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1] : sorted[0] + 2 * count
            let first = place / 2 + 1
            let length = (next + 1) / 2 - first
            if length > (best?.length ?? 0) {
                best = (first % count, length)
            }
        }
        return best
    }
}

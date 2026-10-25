import Foundation
import CourseDataSwift

/// A `leisure=golf_course` element that is not a usable course outline, such as a node or the
/// clubhouse building. The OSM wiki says the tag belongs on the area of the whole course.
struct MisplacedCourseElement: Codable, Hashable {
    /// Such as `n123`, `w123`, or `r123`.
    var osmID: String
    var version: Int?
    var tags: [String: String]
    /// The middle of the element, used to pick the one nearest the course.
    var center: Coordinate

    var isNode: Bool { osmID.hasPrefix("n") }
}

/// A new course outline to publish, with the tags it takes from the misplaced element.
struct PendingCourseOutline: Codable, Hashable {
    /// The outline's points as `[latitude, longitude]`, open (the first point is not repeated).
    var points: [[Double]]
    /// The tags the new way gets.
    var tags: [String: String]
    /// Whether the old way or relation gets `golf=clubhouse`.
    var tagsOldElementClubhouse: Bool

    var coordinates: [Coordinate] {
        points.map { Coordinate(lat: $0[0], lon: $0[1]) }
    }

    init(coordinates: [Coordinate], tags: [String: String], tagsOldElementClubhouse: Bool) {
        self.points = coordinates.map { [$0.lat, $0.lon] }
        self.tags = tags
        self.tagsOldElementClubhouse = tagsOldElementClubhouse
    }
}

enum CourseOutline {
    /// The ID the map editor uses for the pending outline. It is never written to the course.
    static let featureID = -1

    /// Keys whose tags describe the course rather than a building, so they move to the outline.
    private static let courseKeys: Set<String> = [
        "leisure", "name", "alt_name", "website", "phone", "email", "operator", "opening_hours",
        "access", "golf:par", "holes", "par",
    ]
    /// Key prefixes whose tags move to the outline.
    private static let courseKeyPrefixes = ["name:", "payment:"]

    /// Whether the tag starts checked in the sheet. Every tag of a node moves.
    static func movesByDefault(key: String, from element: MisplacedCourseElement) -> Bool {
        element.isNode || courseKeys.contains(key) || courseKeyPrefixes.contains { key.hasPrefix($0) }
    }

    /// Whether the tag must move. Every tag of a node moves, since the node is deleted, and the
    /// outline always gets `leisure`.
    static func mustMove(key: String, from element: MisplacedCourseElement) -> Bool {
        element.isNode || key == "leisure"
    }

    /// Whether the sheet offers to tag the old element `golf=clubhouse`.
    static func offersClubhouseTag(for element: MisplacedCourseElement) -> Bool {
        !element.isNode && element.tags["golf"] != "clubhouse"
    }

    /// Whether `golf=clubhouse` starts checked: the old element is a building.
    static func clubhouseTagByDefault(for element: MisplacedCourseElement) -> Bool {
        offersClubhouseTag(for: element) && element.tags["building"] != nil
    }

    /// The old element's tags after the outline takes its tags.
    static func remainingTags(_ tags: [String: String], outline: PendingCourseOutline) -> [String: String] {
        var tags = tags.filter { outline.tags[$0.key] == nil }
        if outline.tagsOldElementClubhouse {
            tags["golf"] = "clubhouse"
        }
        return tags
    }

    /// The misplaced element nearest the point. Nil when there are none.
    static func nearest(_ elements: [MisplacedCourseElement], to point: Coordinate) -> MisplacedCourseElement? {
        elements.min { OSMChangeDetector.distanceMeters($0.center, point) < OSMChangeDetector.distanceMeters($1.center, point) }
    }

    /// An outline about `marginMeters` outside every feature and centerline, except water, which
    /// can be far larger than the course. Open, counterclockwise, and convex. Empty when the
    /// course has fewer than 3 points.
    static func hull(for course: Course, marginMeters: Double = 30) -> [Coordinate] {
        let points = course.features.filter { $0.type != .water }.flatMap(\.polygon)
        guard points.count >= 3 else { return [] }
        let latMeters = 111_320.0
        let lonMeters = latMeters * cos(points.map(\.lat).reduce(0, +) / Double(points.count) * .pi / 180)
        let circle = (0..<8).map { Double($0) * .pi / 4 }
        let padded = points.flatMap { point in
            circle.map { angle in
                Coordinate(
                    lat: point.lat + marginMeters * sin(angle) / latMeters,
                    lon: point.lon + marginMeters * cos(angle) / lonMeters
                )
            }
        }
        return convexHull(padded)
    }

    /// The convex hull by the monotone chain method, counterclockwise, without repeated points.
    static func convexHull(_ points: [Coordinate]) -> [Coordinate] {
        let sorted = points.sorted { ($0.lon, $0.lat) < ($1.lon, $1.lat) }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
            (a.lon - o.lon) * (b.lat - o.lat) - (a.lat - o.lat) * (b.lon - o.lon)
        }
        var lower: [Coordinate] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        var upper: [Coordinate] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

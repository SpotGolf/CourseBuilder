import Foundation
import CourseDataSwift

/// A fairway way that becomes a multipolygon relation on the next publish, with the greens
/// inside it as inner members. OSM's golf course guidance asks for this when a fringe of
/// fairway surrounds a green.
struct PendingMultipolygon: Codable, Equatable {
    /// The fairway way, such as `w123`. It becomes the outer member and loses its tags.
    var fairwayOSMID: String
    /// The green ways inside the fairway. They become inner members and keep their tags.
    var innerOSMIDs: [String]
}

enum OSMMultipolygon {
    /// The greens that can be inner members of a multipolygon made from the fairway: greens
    /// already in OSM as ways, with every point inside the fairway's outline.
    ///
    /// Empty unless the fairway is itself an OSM way.
    static func containedGreens(in fairway: Feature, course: Course) -> [Feature] {
        guard fairway.type == .fairway, fairway.osmID?.hasPrefix("w") == true, fairway.polygon.count >= 3 else { return [] }
        return course.features.filter { green in
            green.type == .green
                && green.osmID?.hasPrefix("w") == true
                && !green.polygon.isEmpty
                && green.polygon.allSatisfy { PolygonGeometry.contains($0, in: fairway.polygon) }
        }
    }

    /// The pending multipolygon for the fairway, if one is recorded.
    static func pending(for fairway: Feature, in baseline: OSMBaseline) -> PendingMultipolygon? {
        guard let osmID = fairway.osmID else { return nil }
        return baseline.pendingMultipolygons.first { $0.fairwayOSMID == osmID }
    }
}

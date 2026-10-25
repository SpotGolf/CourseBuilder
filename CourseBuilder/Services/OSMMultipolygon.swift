import Foundation
import CourseDataSwift

/// A fairway that gets the greens inside it as inner members on the next publish. OSM's golf
/// course guidance asks for this when a fringe of fairway surrounds a green.
///
/// A fairway way becomes a multipolygon relation. A fairway relation gets the greens it is
/// missing added as inner members.
struct PendingMultipolygon: Codable, Equatable {
    /// The fairway, such as `w123` or `r123`. A way becomes the outer member and loses its tags.
    var fairwayOSMID: String
    /// The green ways inside the fairway. They become inner members and keep their tags.
    var innerOSMIDs: [String]
}

enum OSMMultipolygon {
    /// The greens that can be inner members of a multipolygon made from the fairway: greens
    /// already in OSM as ways, with every point inside the fairway's outline.
    ///
    /// Empty unless the fairway is itself an OSM way or relation.
    static func containedGreens(in fairway: Feature, course: Course) -> [Feature] {
        guard fairway.type == .fairway, fairway.polygon.count >= 3,
              let osmID = fairway.osmID, osmID.hasPrefix("w") || osmID.hasPrefix("r") else { return [] }
        return course.features.filter { green in
            green.type == .green
                && green.osmID?.hasPrefix("w") == true
                && !green.polygon.isEmpty
                && green.polygon.allSatisfy { PolygonGeometry.contains($0, in: fairway.polygon) }
        }
    }

    /// The contained greens that are not yet inner members of the fairway. For a fairway relation,
    /// greens the baseline lists as its inner members are left out.
    static func missingGreens(in fairway: Feature, course: Course, baseline: OSMBaseline) -> [Feature] {
        let known = Set(fairway.osmID.flatMap { baseline.entries[$0]?.innerOSMIDs } ?? [])
        return containedGreens(in: fairway, course: course).filter { !known.contains($0.osmID ?? "") }
    }

    /// The pending multipolygon for the fairway, if one is recorded.
    static func pending(for fairway: Feature, in baseline: OSMBaseline) -> PendingMultipolygon? {
        guard let osmID = fairway.osmID else { return nil }
        return baseline.pendingMultipolygons.first { $0.fairwayOSMID == osmID }
    }
}

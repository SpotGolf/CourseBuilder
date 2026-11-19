import Foundation
import CourseDataSwift

/// A fairway that gets the features inside it as inner members on the next publish. OSM's golf
/// course guidance asks for this when fairway surrounds another feature, such as a green with a
/// fringe of fairway around it.
///
/// A fairway way becomes a multipolygon relation with every feature inside it as an inner member.
/// A fairway relation gets the features inside it that it is missing added as inner members.
struct PendingMultipolygon: Codable, Equatable {
    /// The fairway, such as `w123` or `r123`. A way becomes the outer member and loses its tags.
    var fairwayOSMID: String
    /// The ways inside the fairway. They become inner members and keep their tags.
    var innerOSMIDs: [String]
}

enum OSMMultipolygon {
    /// The features that can be inner members of a multipolygon made from the fairway: features
    /// already in OSM as ways, fully inside the fairway's outline. Centerlines are left out,
    /// because they are lines and not shapes.
    ///
    /// A feature that crosses the fairway's outline is left out. So is a feature inside another
    /// contained feature, because OSM does not allow an inner ring inside another inner ring.
    ///
    /// Empty unless the fairway is itself an OSM way or relation.
    static func containedFeatures(in fairway: Feature, course: Course) -> [Feature] {
        guard fairway.type == .fairway, fairway.polygon.count >= 3,
              let osmID = fairway.osmID, osmID.hasPrefix("w") || osmID.hasPrefix("r") else { return [] }
        let outline = Array(fairway.polygon)
        let contained = course.features.filter { feature in
            feature.id != fairway.id
                && feature.type != .centerline
                && feature.osmID?.hasPrefix("w") == true
                && feature.osmID != osmID
                && isInside(Array(feature.polygon), outline)
        }
        return contained.filter { feature in
            let points = Array(feature.polygon)
            return !contained.contains { other in
                guard other.id != feature.id, isInside(points, Array(other.polygon)) else { return false }
                // Two features inside each other are copies. The first one is kept.
                return !isInside(Array(other.polygon), points) || other.id < feature.id
            }
        }
    }

    /// The contained features that are not yet inner members of the fairway: every contained
    /// feature for a fairway way, and for a fairway relation the ones the baseline does not list
    /// as its inner members.
    static func missingFeatures(in fairway: Feature, course: Course, baseline: OSMBaseline) -> [Feature] {
        let known = Set(fairway.osmID.flatMap { baseline.entries[$0]?.innerOSMIDs } ?? [])
        return containedFeatures(in: fairway, course: course).filter { !known.contains($0.osmID ?? "") }
    }

    /// The pending multipolygon for the fairway, if one is recorded.
    static func pending(for fairway: Feature, in baseline: OSMBaseline) -> PendingMultipolygon? {
        guard let osmID = fairway.osmID else { return nil }
        return baseline.pendingMultipolygons.first { $0.fairwayOSMID == osmID }
    }

    /// Whether every point of the shape is inside the outline and no edge of the shape crosses an
    /// edge of the outline. The edge check catches a shape that cuts across a bend in the outline.
    private static func isInside(_ shape: [Coordinate], _ outline: [Coordinate]) -> Bool {
        guard !shape.isEmpty, outline.count >= 3,
              shape.allSatisfy({ PolygonGeometry.contains($0, in: outline) }) else { return false }
        for i in shape.indices {
            let a = shape[i], b = shape[(i + 1) % shape.count]
            for j in outline.indices where crosses(a, b, outline[j], outline[(j + 1) % outline.count]) {
                return false
            }
        }
        return true
    }

    /// Whether segment `a`–`b` crosses segment `c`–`d` at a point inside both.
    static func crosses(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate, _ d: Coordinate) -> Bool {
        func side(_ p: Coordinate, _ q: Coordinate, _ r: Coordinate) -> Double {
            (q.lon - p.lon) * (r.lat - p.lat) - (q.lat - p.lat) * (r.lon - p.lon)
        }
        let d1 = side(c, d, a), d2 = side(c, d, b), d3 = side(a, b, c), d4 = side(a, b, d)
        return ((d1 > 0) != (d2 > 0)) && d1 != 0 && d2 != 0
            && ((d3 > 0) != (d4 > 0)) && d3 != 0 && d4 != 0
    }
}

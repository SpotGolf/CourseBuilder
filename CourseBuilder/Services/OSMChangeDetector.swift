import Foundation
import CourseDataSwift

/// One difference between a course and its ``OSMBaseline``.
struct OSMFeatureChange: Hashable, Identifiable {
    enum Action: Int, Comparable {
        case modify, multipolygon, create, delete

        static func < (lhs: Action, rhs: Action) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let action: Action
    /// The course feature. Nil for a deleted feature.
    let featureID: Int?
    /// The feature's type. For a deleted feature, the type from the baseline.
    let type: FeatureType
    let osmID: String?
    /// The baseline type, when the type changed.
    var oldType: FeatureType? = nil
    var pointsChanged = false
    /// Whether the feature's OSM element is missing its `golf` tag, such as a bunker imported from
    /// a way tagged only `natural=sand`.
    var addsGolfTag = false
    /// For a multipolygon change, the OSM IDs of the inner greens.
    var innerOSMIDs: [String] = []

    var id: String { "\(action)-\(featureID.map(String.init) ?? "")-\(osmID ?? "")" }
}

enum OSMChangeDetector {
    /// Points closer than this are the same point. Course files store points to about 1 foot.
    static let samePointMeters = 0.5

    /// The changes between the course and the baseline: modified, then made into multipolygons,
    /// then created, then deleted.
    ///
    /// Point edits on a relation are sent as edits to its outer way. Features in `ignoredOSMIDs`
    /// are left out of the course on purpose, not deleted, so they are not deleted from OSM.
    static func changes(in course: Course, from baseline: OSMBaseline, ignoredOSMIDs: Set<String> = []) -> [OSMFeatureChange] {
        var changes: [OSMFeatureChange] = []
        var seen: Set<String> = []

        for feature in course.features {
            guard let osmID = feature.osmID else {
                changes.append(OSMFeatureChange(action: .create, featureID: feature.id, type: feature.type, osmID: nil))
                continue
            }
            seen.insert(osmID)
            guard let entry = baseline.entries[osmID] else { continue }

            let typeChanged = entry.type != feature.type
            let pointsChanged = !samePoints(Array(feature.polygon), entry.coordinates)
            // Only bunkers: water tagged only `natural=water` may be a lake that is not a hazard.
            // A type change already adds the new type's tags.
            let addsGolfTag = !typeChanged && feature.type == .bunker && entry.tags != nil && entry.tags?["golf"] == nil

            if typeChanged || pointsChanged || addsGolfTag {
                changes.append(OSMFeatureChange(
                    action: .modify,
                    featureID: feature.id,
                    type: feature.type,
                    osmID: osmID,
                    oldType: typeChanged ? entry.type : nil,
                    pointsChanged: pointsChanged,
                    addsGolfTag: addsGolfTag
                ))
            }
        }

        let courseOSMIDs = Set(course.features.compactMap(\.osmID))
        for pending in baseline.pendingMultipolygons {
            // A fairway or green deleted since the conversion was asked for is left out.
            let inner = pending.innerOSMIDs.filter(courseOSMIDs.contains)
            guard let fairway = course.features.first(where: { $0.osmID == pending.fairwayOSMID }), !inner.isEmpty else { continue }
            changes.append(OSMFeatureChange(
                action: .multipolygon,
                featureID: fairway.id,
                type: fairway.type,
                osmID: pending.fairwayOSMID,
                innerOSMIDs: inner
            ))
        }

        for entry in baseline.entries.values.sorted(by: { $0.osmID < $1.osmID })
        where !seen.contains(entry.osmID) && !ignoredOSMIDs.contains(entry.osmID) {
            changes.append(OSMFeatureChange(action: .delete, featureID: nil, type: entry.type, osmID: entry.osmID))
        }

        // Stable sort keeps feature order within each action.
        return changes.enumerated()
            .sorted { ($0.element.action, $0.offset) < ($1.element.action, $1.offset) }
            .map(\.element)
    }

    /// Whether the two lists have the same number of points and each point is within
    /// ``samePointMeters`` of the point at the same position.
    static func samePoints(_ a: [Coordinate], _ b: [Coordinate]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { distanceMeters($0, $1) <= samePointMeters }
    }

    /// Distance in meters, flat-earth. Accurate at the short distances it is used for.
    static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let metersPerDegree = 111_320.0
        let dLat = (a.lat - b.lat) * metersPerDegree
        let dLon = (a.lon - b.lon) * metersPerDegree * cos((a.lat + b.lat) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}

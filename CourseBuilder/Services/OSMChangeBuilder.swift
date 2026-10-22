import Foundation
import CourseDataSwift

/// OSM elements as the API returns them.
struct OSMNode: Equatable {
    let id: Int
    let version: Int
    let lat: Double
    let lon: Double
    var tags: [String: String] = [:]
}

struct OSMWay: Equatable {
    let id: Int
    let version: Int
    var nodes: [Int]
    var tags: [String: String]
}

struct OSMRelation: Equatable {
    struct Member: Equatable {
        let type: String
        let ref: Int
        let role: String
    }

    let id: Int
    let version: Int
    var members: [Member]
    var tags: [String: String]
}

/// A way and its nodes, from `/way/{id}/full`.
struct OSMWayFull: Equatable {
    let way: OSMWay
    let nodes: [Int: OSMNode]
}

/// The current OSM elements for the features being modified or deleted.
struct OSMFetchedElements: Equatable {
    var ways: [Int: OSMWayFull] = [:]
    var relations: [Int: OSMRelation] = [:]
    /// The one outer way of each relation whose points are edited, by relation ID.
    var outerWays: [Int: Int] = [:]

    /// The fetched version of an element, by its short OSM ID.
    func version(of osmID: String) -> Int? {
        guard let (kind, id) = OSMChangeBuilder.parse(osmID) else { return nil }
        switch kind {
        case "w": return ways[id]?.way.version
        case "r": return relations[id]?.version
        default: return nil
        }
    }
}

/// One element in the `diffResult` OSM returns for an upload.
struct OSMDiffEntry: Equatable {
    let type: String
    let oldID: Int
    let newID: Int?
    let newVersion: Int?
}

/// Builds the `osmChange` upload for a list of changes, and applies OSM's answer to the course.
enum OSMChangeBuilder {
    struct Upload: Equatable {
        let xml: String
        /// The feature ID of each created way, by its placeholder (negative) way ID.
        let createdWays: [Int: Int]
        /// The fairway feature ID of each created multipolygon, by its placeholder (negative) relation ID.
        var createdRelations: [Int: Int] = [:]
    }

    // MARK: - Tags

    /// The tags a feature of this type gets in OSM. A centerline also gets its hole's number and par.
    static func tags(for type: FeatureType, hole: Hole? = nil) -> [String: String] {
        switch type {
        case .fairway: return ["golf": "fairway"]
        case .green: return ["golf": "green"]
        case .tee: return ["golf": "tee"]
        case .bunker: return ["golf": "bunker", "natural": "sand"]
        case .water: return ["golf": "water_hazard", "natural": "water"]
        case .centerline:
            var tags = ["golf": "hole"]
            if let hole {
                tags["ref"] = String(hole.number)
                tags["par"] = String(hole.par)
            }
            return tags
        }
    }

    /// The tag values that mark a type, used to remove them when the type changes.
    private static func typeMarkers(for type: FeatureType) -> [String: Set<String>] {
        switch type {
        case .fairway: return ["golf": ["fairway"]]
        case .green: return ["golf": ["green"]]
        case .tee: return ["golf": ["tee"]]
        case .bunker: return ["golf": ["bunker"], "natural": ["sand"]]
        case .water: return ["golf": ["water_hazard", "lateral_water_hazard"], "natural": ["water"]]
        case .centerline: return ["golf": ["hole"]]
        }
    }

    /// Removes the old type's tags that are present, then adds the new type's tags. Other tags are kept.
    static func retag(_ existing: [String: String], from oldType: FeatureType, to newType: FeatureType) -> [String: String] {
        var result = existing
        for (key, values) in typeMarkers(for: oldType) where result[key].map(values.contains) == true {
            result.removeValue(forKey: key)
        }
        result.merge(tags(for: newType)) { _, new in new }
        return result
    }

    // MARK: - Nodes

    /// The node list for a way with the given points.
    ///
    /// Each point reuses an existing node within ``OSMChangeDetector/samePointMeters``. Other
    /// points become new nodes with negative IDs taken from `nextID`. Repeated nodes in a row are
    /// dropped, and a closed way ends with its first node.
    static func nodeList(
        for points: [Coordinate],
        closed: Bool,
        existing: [OSMNode],
        nextID: inout Int
    ) -> (refs: [Int], newNodes: [OSMNode]) {
        var refs: [Int] = []
        var newNodes: [OSMNode] = []
        for point in points {
            let nearest = existing.min {
                OSMChangeDetector.distanceMeters($0.coordinate, point) < OSMChangeDetector.distanceMeters($1.coordinate, point)
            }
            let ref: Int
            if let nearest, OSMChangeDetector.distanceMeters(nearest.coordinate, point) <= OSMChangeDetector.samePointMeters {
                ref = nearest.id
            } else {
                ref = nextID
                newNodes.append(OSMNode(id: nextID, version: 0, lat: point.lat, lon: point.lon))
                nextID -= 1
            }
            if refs.last != ref {
                refs.append(ref)
            }
        }
        if closed, let first = refs.first, refs.count > 1, refs.last != first {
            refs.append(first)
        }
        return (refs, newNodes)
    }

    // MARK: - Upload

    /// The OSM IDs whose current version is not the baseline version.
    static func conflicts(
        in changes: [OSMFeatureChange],
        baseline: OSMBaseline,
        fetched: OSMFetchedElements
    ) -> [String] {
        changes.compactMap { change in
            guard change.action == .modify || change.action == .delete || change.action == .multipolygon,
                  let osmID = change.osmID,
                  let known = baseline.entries[osmID]?.version,
                  let current = fetched.version(of: osmID),
                  known != current else { return nil }
            return osmID
        }
    }

    /// Builds the `osmChange` XML for the sent changes.
    ///
    /// Point edits on a relation go to its one outer way. A multipolygon change makes a relation
    /// with the fairway way as its outer member and the greens as inner members, and moves the
    /// fairway way's tags to the relation.
    static func upload(
        for changes: [OSMFeatureChange],
        course: Course,
        fetched: OSMFetchedElements,
        changesetID: Int
    ) -> Upload {
        var nextID = -1
        var createdNodes: [OSMNode] = []
        var createdWays: [OSMWay] = []
        var createdWayFeatures: [Int: Int] = [:]
        var createdRelations: [OSMRelation] = []
        var createdRelationFeatures: [Int: Int] = [:]
        // Kept in order of first change so the XML is stable.
        var modifiedWayIDs: [Int] = []
        var modifiedWays: [Int: OSMWay] = [:]
        var modifiedRelations: [OSMRelation] = []
        var deletedWays: [OSMWay] = []
        var unusedNodes: [Int: OSMNode] = [:]
        var usedNodes: Set<Int> = []

        /// The way as already changed in this upload, or as fetched.
        func currentWay(_ id: Int) -> OSMWay? {
            modifiedWays[id] ?? fetched.ways[id]?.way
        }
        func modify(_ way: OSMWay) {
            if modifiedWays[way.id] == nil { modifiedWayIDs.append(way.id) }
            modifiedWays[way.id] = way
        }
        /// Moves the way onto the feature's points, reusing its nodes where they still fit.
        func reshape(_ way: inout OSMWay, to feature: Feature) {
            guard let full = fetched.ways[way.id] else { return }
            let existing = full.way.nodes.compactMap { full.nodes[$0] }
            let (refs, newNodes) = nodeList(
                for: Array(feature.polygon),
                closed: feature.type != .centerline,
                existing: existing,
                nextID: &nextID
            )
            createdNodes.append(contentsOf: newNodes)
            for node in existing where !refs.contains(node.id) && node.tags.isEmpty {
                unusedNodes[node.id] = node
            }
            way.nodes = refs
        }

        for change in changes where change.isSent {
            switch change.action {
            case .create:
                guard let featureID = change.featureID, let feature = course.findFeature(id: featureID) else { continue }
                let (refs, newNodes) = nodeList(
                    for: Array(feature.polygon),
                    closed: feature.type != .centerline,
                    existing: [],
                    nextID: &nextID
                )
                createdNodes.append(contentsOf: newNodes)
                let wayID = nextID
                nextID -= 1
                createdWays.append(OSMWay(id: wayID, version: 0, nodes: refs, tags: tags(for: feature.type, hole: hole(using: featureID, in: course))))
                createdWayFeatures[wayID] = featureID

            case .modify:
                guard let featureID = change.featureID,
                      let feature = course.findFeature(id: featureID),
                      let osmID = change.osmID,
                      let (kind, id) = parse(osmID) else { continue }
                if kind == "r", var relation = fetched.relations[id] {
                    if let oldType = change.oldType {
                        relation.tags = retag(relation.tags, from: oldType, to: feature.type)
                        modifiedRelations.append(relation)
                    }
                    if change.pointsChanged, let outerID = fetched.outerWays[id], var outer = currentWay(outerID) {
                        reshape(&outer, to: feature)
                        modify(outer)
                    }
                } else if kind == "w", var way = currentWay(id) {
                    if let oldType = change.oldType {
                        way.tags = retag(way.tags, from: oldType, to: feature.type)
                    }
                    if change.pointsChanged {
                        reshape(&way, to: feature)
                    }
                    modify(way)
                }

            case .multipolygon:
                guard let featureID = change.featureID,
                      let osmID = change.osmID,
                      let (kind, id) = parse(osmID), kind == "w",
                      var fairway = currentWay(id) else { continue }
                let relationID = nextID
                nextID -= 1
                var members = [OSMRelation.Member(type: "way", ref: id, role: "outer")]
                for inner in change.innerOSMIDs {
                    guard let (innerKind, innerID) = parse(inner), innerKind == "w" else { continue }
                    members.append(OSMRelation.Member(type: "way", ref: innerID, role: "inner"))
                }
                var relationTags = fairway.tags
                relationTags["type"] = "multipolygon"
                createdRelations.append(OSMRelation(id: relationID, version: 0, members: members, tags: relationTags))
                createdRelationFeatures[relationID] = featureID
                fairway.tags = [:]
                modify(fairway)

            case .delete:
                guard let osmID = change.osmID, let (kind, id) = parse(osmID), kind == "w",
                      let full = fetched.ways[id] else { continue }
                deletedWays.append(full.way)
                for node in full.way.nodes.compactMap({ full.nodes[$0] }) where node.tags.isEmpty {
                    unusedNodes[node.id] = node
                }

            case .skip:
                continue
            }
        }

        for way in modifiedWays.values {
            usedNodes.formUnion(way.nodes)
        }
        let deletedNodes = unusedNodes.values.filter { !usedNodes.contains($0.id) }.sorted { $0.id < $1.id }
        var xml = "<osmChange version=\"0.6\" generator=\"CourseBuilder\">\n"
        if !createdNodes.isEmpty || !createdWays.isEmpty || !createdRelations.isEmpty {
            xml += "<create>\n"
            createdNodes.forEach { xml += nodeXML($0, changesetID: changesetID, includeVersion: false) }
            createdWays.forEach { xml += wayXML($0, changesetID: changesetID, includeVersion: false) }
            createdRelations.forEach { xml += relationXML($0, changesetID: changesetID, includeVersion: false) }
            xml += "</create>\n"
        }
        if !modifiedWayIDs.isEmpty || !modifiedRelations.isEmpty {
            xml += "<modify>\n"
            modifiedWayIDs.compactMap { modifiedWays[$0] }.forEach { xml += wayXML($0, changesetID: changesetID, includeVersion: true) }
            modifiedRelations.forEach { xml += relationXML($0, changesetID: changesetID, includeVersion: true) }
            xml += "</modify>\n"
        }
        if !deletedWays.isEmpty || !deletedNodes.isEmpty {
            // OSM skips any element that is still used, such as a node another way shares.
            xml += "<delete if-unused=\"true\">\n"
            deletedWays.forEach { xml += "  <way id=\"\($0.id)\" version=\"\($0.version)\" changeset=\"\(changesetID)\"/>\n" }
            deletedNodes.forEach { xml += nodeXML($0, changesetID: changesetID, includeVersion: true) }
            xml += "</delete>\n"
        }
        xml += "</osmChange>\n"
        return Upload(xml: xml, createdWays: createdWayFeatures, createdRelations: createdRelationFeatures)
    }

    // MARK: - Result

    /// Applies OSM's answer to an upload: created features get their new OSM IDs, fairways made
    /// into multipolygons get their relation IDs, and the baseline takes the sent state and new
    /// versions.
    static func apply(
        _ diff: [OSMDiffEntry],
        upload: Upload,
        changes: [OSMFeatureChange],
        course: inout Course,
        baseline: OSMBaseline
    ) -> OSMBaseline {
        var result = baseline
        var newWayVersions: [Int: Int] = [:]
        var newRelationVersions: [Int: Int] = [:]
        for entry in diff {
            if entry.type == "way", let version = entry.newVersion { newWayVersions[entry.oldID] = version }
            if entry.type == "relation", let version = entry.newVersion { newRelationVersions[entry.oldID] = version }
        }

        for entry in diff where entry.type == "way" {
            guard let featureID = upload.createdWays[entry.oldID], let newID = entry.newID,
                  let index = course.features.firstIndex(where: { $0.id == featureID }) else { continue }
            let osmID = "w\(newID)"
            course.features[index].osmID = osmID
            result.entries[osmID] = OSMBaseline.Entry(feature: course.features[index], osmID: osmID, version: entry.newVersion)
        }

        for change in changes where change.isSent {
            guard let osmID = change.osmID, let (kind, id) = parse(osmID) else { continue }
            switch change.action {
            case .modify:
                guard let featureID = change.featureID, let feature = course.findFeature(id: featureID),
                      var entry = result.entries[osmID] else { continue }
                entry.type = feature.type
                if change.pointsChanged {
                    entry.points = feature.polygon.map { [$0.lat, $0.lon] }
                }
                // A relation whose outer way changed but whose tags did not keeps its version.
                entry.version = kind == "r" ? (newRelationVersions[id] ?? entry.version) : newWayVersions[id]
                result.entries[osmID] = entry
            case .delete:
                result.entries.removeValue(forKey: osmID)
            case .multipolygon:
                result.pendingMultipolygons.removeAll { $0.fairwayOSMID == osmID }
            case .create, .skip:
                break
            }
        }

        for entry in diff where entry.type == "relation" {
            guard let featureID = upload.createdRelations[entry.oldID], let newID = entry.newID,
                  let index = course.features.firstIndex(where: { $0.id == featureID }) else { continue }
            if let wayOSMID = course.features[index].osmID {
                result.entries.removeValue(forKey: wayOSMID)
            }
            let osmID = "r\(newID)"
            course.features[index].osmID = osmID
            result.entries[osmID] = OSMBaseline.Entry(feature: course.features[index], osmID: osmID, version: entry.newVersion)
        }
        return result
    }

    // MARK: - Helpers

    /// Splits a short OSM ID such as `w123` into its kind letter and number.
    static func parse(_ osmID: String) -> (kind: String, id: Int)? {
        guard let first = osmID.first, let id = Int(osmID.dropFirst()) else { return nil }
        return (String(first), id)
    }

    /// The hole whose centerline is the feature.
    private static func hole(using featureID: Int, in course: Course) -> Hole? {
        course.subCourses.flatMap(\.holes).first { $0.centerline == featureID }
    }

    private static func nodeXML(_ node: OSMNode, changesetID: Int, includeVersion: Bool) -> String {
        let version = includeVersion ? " version=\"\(node.version)\"" : ""
        let lat = String(format: "%.7f", node.lat)
        let lon = String(format: "%.7f", node.lon)
        return "  <node id=\"\(node.id)\"\(version) changeset=\"\(changesetID)\" lat=\"\(lat)\" lon=\"\(lon)\"/>\n"
    }

    private static func wayXML(_ way: OSMWay, changesetID: Int, includeVersion: Bool) -> String {
        let version = includeVersion ? " version=\"\(way.version)\"" : ""
        var xml = "  <way id=\"\(way.id)\"\(version) changeset=\"\(changesetID)\">\n"
        way.nodes.forEach { xml += "    <nd ref=\"\($0)\"/>\n" }
        xml += tagsXML(way.tags)
        xml += "  </way>\n"
        return xml
    }

    private static func relationXML(_ relation: OSMRelation, changesetID: Int, includeVersion: Bool) -> String {
        let version = includeVersion ? " version=\"\(relation.version)\"" : ""
        var xml = "  <relation id=\"\(relation.id)\"\(version) changeset=\"\(changesetID)\">\n"
        for member in relation.members {
            xml += "    <member type=\"\(escape(member.type))\" ref=\"\(member.ref)\" role=\"\(escape(member.role))\"/>\n"
        }
        xml += tagsXML(relation.tags)
        xml += "  </relation>\n"
        return xml
    }

    private static func tagsXML(_ tags: [String: String]) -> String {
        tags.sorted { $0.key < $1.key }
            .map { "    <tag k=\"\(escape($0.key))\" v=\"\(escape($0.value))\"/>\n" }
            .joined()
    }

    /// Escapes a value for an XML attribute.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }
}

extension OSMNode {
    var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
}

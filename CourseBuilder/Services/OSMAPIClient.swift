import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "OSMAPI")

/// Talks to the OSM editing API (0.6) as the signed-in user.
struct OSMAPIClient {
    enum APIError: LocalizedError, Equatable {
        case http(statusCode: Int, message: String)
        case conflict(message: String)
        case conflicts(osmIDs: [String])
        case multipleOuterWays(osmID: String, count: Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let message):
                message.isEmpty ? "OpenStreetMap returned HTTP \(code)." : "OpenStreetMap returned HTTP \(code): \(message)"
            case .conflict(let message):
                "Someone changed these features in OpenStreetMap: \(message)"
            case .conflicts(let osmIDs):
                "Someone changed \(osmIDs.count) of these features in OpenStreetMap since they were imported."
            case .multipleOuterWays(let osmID, let count):
                "Relation \(osmID) has \(count) outer ways. CourseBuilder can only change the outline of a relation with one outer way."
            case .invalidResponse:
                "OpenStreetMap sent an answer CourseBuilder could not read."
            }
        }
    }

    /// The outcome of a publish.
    struct PublishResult {
        let course: Course
        let baseline: OSMBaseline
        let changesetID: Int
    }

    let token: String
    var session: URLSession = .shared

    // MARK: - Reads

    /// The signed-in user's display name.
    func displayName() async throws -> String {
        let data = try await send("GET", "user/details.json")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any],
              let name = user["display_name"] as? String else { throw APIError.invalidResponse }
        return name
    }

    func wayFull(id: Int) async throws -> OSMWayFull {
        let elements = try elements(from: try await send("GET", "way/\(id)/full.json"))
        var nodes: [Int: OSMNode] = [:]
        var way: OSMWay?
        for element in elements {
            switch element["type"] as? String {
            case "node":
                guard let node = Self.node(from: element) else { throw APIError.invalidResponse }
                nodes[node.id] = node
            case "way":
                guard let id = element["id"] as? Int, let version = element["version"] as? Int,
                      let refs = element["nodes"] as? [Int] else { throw APIError.invalidResponse }
                way = OSMWay(id: id, version: version, nodes: refs, tags: Self.tags(from: element))
            default:
                continue
            }
        }
        guard let way else { throw APIError.invalidResponse }
        return OSMWayFull(way: way, nodes: nodes)
    }

    /// The most elements read in one request, which keeps the URL short.
    static let detailsBatchSize = 100

    /// The current version, tags, and members of ways and relations, by short OSM ID such as
    /// `w123`. Other IDs are ignored. Reading needs no sign in.
    static func details(of osmIDs: [String], session: URLSession = .shared) async throws -> [String: OSMElementDetails] {
        var details: [String: OSMElementDetails] = [:]
        for (kind, plural) in [("w", "ways"), ("r", "relations")] {
            let ids = osmIDs.compactMap(OSMChangeBuilder.parse).filter { $0.kind == kind }.map(\.id)
            for start in stride(from: 0, to: ids.count, by: detailsBatchSize) {
                let batch = ids[start..<min(start + detailsBatchSize, ids.count)]
                var components = URLComponents(url: OSMServer.apiURL.appendingPathComponent("\(plural).json"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: plural, value: batch.map(String.init).joined(separator: ","))]
                let (data, response) = try await session.data(from: components.url!)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard statusCode == 200 else { throw APIError.http(statusCode: statusCode, message: "") }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else { throw APIError.invalidResponse }
                for element in elements {
                    guard let osmID = OverpassAPIClient.osmID(of: element) else { continue }
                    details[osmID] = OSMElementDetails(
                        version: element["version"] as? Int,
                        tags: Self.tags(from: element),
                        members: OverpassAPIClient.members(of: element)
                    )
                }
            }
        }
        return details
    }

    func relation(id: Int) async throws -> OSMRelation {
        let elements = try elements(from: try await send("GET", "relation/\(id).json"))
        guard let element = elements.first(where: { $0["type"] as? String == "relation" }),
              let version = element["version"] as? Int,
              let rawMembers = element["members"] as? [[String: Any]] else { throw APIError.invalidResponse }
        let members = try rawMembers.map { member in
            guard let type = member["type"] as? String, let ref = member["ref"] as? Int else { throw APIError.invalidResponse }
            return OSMRelation.Member(type: type, ref: ref, role: member["role"] as? String ?? "")
        }
        return OSMRelation(id: id, version: version, members: members, tags: Self.tags(from: element))
    }

    /// The current elements for every change that modifies or deletes an OSM element.
    ///
    /// A relation whose points changed also gets its outer way. Throws
    /// ``APIError/multipleOuterWays(osmID:count:)`` when it does not have exactly one. A deleted
    /// relation also gets all of its outer ways. Ways whose nodes a change reuses are fetched too.
    /// One that can't be fetched is skipped, and its nodes are not reused.
    func fetchElements(for changes: [OSMFeatureChange]) async throws -> OSMFetchedElements {
        var fetched = OSMFetchedElements()
        for change in changes where change.action == .modify || change.action == .delete || change.action == .multipolygon {
            guard let osmID = change.osmID, let (kind, id) = OSMChangeBuilder.parse(osmID) else { continue }
            for shared in change.sharedNodeOSMIDs {
                guard let (_, wayID) = OSMChangeBuilder.parse(shared), fetched.ways[wayID] == nil else { continue }
                fetched.ways[wayID] = try? await wayFull(id: wayID)
            }
            switch kind {
            case "w":
                if fetched.ways[id] == nil {
                    fetched.ways[id] = try await wayFull(id: id)
                }
            case "r":
                let relation = try await relation(id: id)
                fetched.relations[id] = relation
                if change.action == .delete {
                    for member in relation.members where member.type == "way" && member.role == "outer" && fetched.ways[member.ref] == nil {
                        fetched.ways[member.ref] = try await wayFull(id: member.ref)
                    }
                    continue
                }
                guard change.pointsChanged else { continue }
                let outers = relation.members.filter { $0.type == "way" && $0.role == "outer" }
                guard outers.count == 1 else { throw APIError.multipleOuterWays(osmID: osmID, count: outers.count) }
                fetched.outerWays[id] = outers[0].ref
                fetched.ways[outers[0].ref] = try await wayFull(id: outers[0].ref)
            default:
                continue
            }
        }
        return fetched
    }

    // MARK: - Changesets

    func createChangeset(comment: String) async throws -> Int {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let body = """
        <osm>
          <changeset>
            <tag k="comment" v="\(OSMChangeBuilder.escape(comment))"/>
            <tag k="created_by" v="\(OSMChangeBuilder.escape("CourseBuilder \(version)"))"/>
          </changeset>
        </osm>
        """
        let data = try await send("PUT", "changeset/create", body: body)
        guard let id = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw APIError.invalidResponse
        }
        return id
    }

    func upload(changesetID: Int, xml: String) async throws -> [OSMDiffEntry] {
        let data = try await send("POST", "changeset/\(changesetID)/upload", body: xml)
        guard let entries = DiffResultParser.parse(data) else { throw APIError.invalidResponse }
        return entries
    }

    func closeChangeset(id: Int) async throws {
        _ = try await send("PUT", "changeset/\(id)/close")
    }

    // MARK: - Publish

    /// Sends the changes in one changeset and returns the course and baseline after the upload.
    ///
    /// Throws ``APIError/conflicts(osmIDs:)`` without sending anything when an element changed in
    /// OSM since the baseline. The changeset is closed even when the upload fails.
    func publish(
        _ changes: [OSMFeatureChange],
        course: Course,
        baseline: OSMBaseline,
        comment: String
    ) async throws -> PublishResult {
        let fetched = try await fetchElements(for: changes)
        let conflicts = OSMChangeBuilder.conflicts(in: changes, baseline: baseline, fetched: fetched)
        guard conflicts.isEmpty else { throw APIError.conflicts(osmIDs: conflicts) }

        let changesetID = try await createChangeset(comment: comment)
        let osmChange = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: changesetID)
        let diff: [OSMDiffEntry]
        do {
            diff = try await upload(changesetID: changesetID, xml: osmChange.xml)
        } catch {
            try? await closeChangeset(id: changesetID)
            throw error
        }
        do {
            try await closeChangeset(id: changesetID)
        } catch {
            // The upload is already applied. OSM closes idle changesets on its own.
            logger.error("Could not close changeset \(changesetID, privacy: .public): \(error, privacy: .public)")
        }

        var updated = course
        let newBaseline = OSMChangeBuilder.apply(diff, upload: osmChange, changes: changes, course: &updated, baseline: baseline)
        return PublishResult(course: updated, baseline: newBaseline, changesetID: changesetID)
    }

    // MARK: - HTTP

    private func send(_ method: String, _ path: String, body: String? = nil) async throws -> Data {
        var request = URLRequest(url: OSMServer.apiURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("\(method, privacy: .public) \(path, privacy: .public) failed with HTTP \(statusCode, privacy: .public): \(message, privacy: .public)")
            if statusCode == 409 {
                throw APIError.conflict(message: message)
            }
            throw APIError.http(statusCode: statusCode, message: message)
        }
        return data
    }

    private func elements(from data: Data) throws -> [[String: Any]] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { throw APIError.invalidResponse }
        return elements
    }

    private static func node(from element: [String: Any]) -> OSMNode? {
        guard let id = element["id"] as? Int, let version = element["version"] as? Int,
              let lat = element["lat"] as? Double, let lon = element["lon"] as? Double else { return nil }
        return OSMNode(id: id, version: version, lat: lat, lon: lon, tags: tags(from: element))
    }

    private static func tags(from element: [String: Any]) -> [String: String] {
        (element["tags"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
    }
}

/// Reads the `diffResult` XML OSM returns for an upload.
final class DiffResultParser: NSObject, XMLParserDelegate {
    private var entries: [OSMDiffEntry] = []

    static func parse(_ data: Data) -> [OSMDiffEntry]? {
        let delegate = DiffResultParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        return parser.parse() ? delegate.entries : nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        guard ["node", "way", "relation"].contains(elementName),
              let oldID = attributes["old_id"].flatMap(Int.init) else { return }
        entries.append(OSMDiffEntry(
            type: elementName,
            oldID: oldID,
            newID: attributes["new_id"].flatMap(Int.init),
            newVersion: attributes["new_version"].flatMap(Int.init)
        ))
    }
}

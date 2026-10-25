import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "OverpassAPI")

actor OverpassAPIClient {
    enum OverpassError: LocalizedError {
        case serverError(statusCode: Int)
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .serverError(let code):
                "Overpass API returned HTTP \(code). Try again in a moment."
            case .rateLimited:
                "Overpass API rate limit exceeded. Try again in a moment."
            }
        }
    }

    struct BoundingBox {
        let south: Double
        let west: Double
        let north: Double
        let east: Double

        /// Smallest box containing every coordinate. Returns nil for an empty list.
        init?(containing coordinates: [Coordinate]) {
            guard let first = coordinates.first else { return nil }
            var south = first.lat, north = first.lat
            var west = first.lon, east = first.lon
            for c in coordinates.dropFirst() {
                south = min(south, c.lat)
                north = max(north, c.lat)
                west = min(west, c.lon)
                east = max(east, c.lon)
            }
            self.init(south: south, west: west, north: north, east: east)
        }

        init(south: Double, west: Double, north: Double, east: Double) {
            self.south = south
            self.west = west
            self.north = north
            self.east = east
        }

        /// Longest side of the box in meters.
        var spanMeters: Double {
            let midLat = (south + north) / 2
            let latMeters = (north - south) * 111_320.0
            let lonMeters = (east - west) * 111_320.0 * cos(midLat * .pi / 180)
            return max(latMeters, lonMeters)
        }

        func padded(by fraction: Double) -> BoundingBox {
            let latSpan = north - south
            let lonSpan = east - west
            return BoundingBox(
                south: south - latSpan * fraction,
                west: west - lonSpan * fraction,
                north: north + latSpan * fraction,
                east: east + lonSpan * fraction
            )
        }
    }

    struct ParsedCenterline {
        let holeNumber: Int?
        let coordinates: [Coordinate]
        /// The OSM element in short form, such as `w123456789`.
        var osmID: String? = nil
        /// The OSM element's version. Nil when the response has no metadata.
        var version: Int? = nil
        var tags: [String: String] = [:]
    }

    struct ParsedResult {
        let features: [ParsedFeature]
        let centerlines: [ParsedCenterline]
        let courseBoundary: [Coordinate]?

        /// The inner way members of the relations in the result that are not in it themselves,
        /// such as a green outside the search area inside a fairway relation that reaches into it.
        var missingInnerWayIDs: [Int] {
            let present = Set(features.compactMap(\.osmID) + centerlines.compactMap(\.osmID))
            let inner = features.flatMap { $0.members ?? [] }.filter { $0.type == "way" && $0.role == "inner" }
            return Array(Set(inner.map(\.ref).filter { !present.contains("w\($0)") })).sorted()
        }

        /// This result with the other result's features and centerlines added. Elements already
        /// in this result are not added again.
        func adding(_ other: ParsedResult) -> ParsedResult {
            let present = Set(features.compactMap(\.osmID) + centerlines.compactMap(\.osmID))
            return ParsedResult(
                features: features + other.features.filter { $0.osmID.map { !present.contains($0) } ?? true },
                centerlines: centerlines + other.centerlines.filter { $0.osmID.map { !present.contains($0) } ?? true },
                courseBoundary: courseBoundary
            )
        }
    }

    struct ParsedFeature {
        let type: FeatureType
        let polygon: [Coordinate]
        /// The OSM element in short form, such as `w123456789`.
        var osmID: String? = nil
        /// The OSM element's version. Nil when the response has no metadata.
        var version: Int? = nil
        var tags: [String: String] = [:]
        /// For a relation, its members. Nil for a way.
        var members: [OSMRelation.Member]? = nil
    }

    /// A course outline narrower than this is not a real boundary (e.g. a mistagged
    /// building) and is ignored in favor of the default search radius.
    static let minimumBoundarySpanMeters = 300.0

    /// Bounding box to refetch within when the parsed course boundary is usable.
    /// Returns nil when there is no boundary, it has too few points, or it is too small.
    static func boundaryBoundingBox(for boundary: [Coordinate]?, padding: Double = 0.25) -> BoundingBox? {
        guard let boundary, boundary.count >= 3,
              let bbox = BoundingBox(containing: boundary),
              bbox.spanMeters >= minimumBoundarySpanMeters else { return nil }
        return bbox.padded(by: padding)
    }

    /// Growing the search area stops after this many more fetches.
    static let maximumGrowthFetches = 4
    /// The search area does not grow past this size, so it does not run into nearby courses.
    static let maximumSearchSpanMeters = 6000.0

    /// For a course with no outline in OSM: the search area grown to hold every golf feature in
    /// the result, plus a margin, so features just past its edge are found on the next fetch.
    /// Water is left out, since a lake next to the course can be far larger than it.
    ///
    /// Returns nil when no side would grow by more than `minimumGrowthMeters`, or the area would
    /// grow past ``maximumSearchSpanMeters``.
    static func grownBoundingBox(
        _ bbox: BoundingBox,
        for result: ParsedResult,
        marginMeters: Double = 150,
        minimumGrowthMeters: Double = 25
    ) -> BoundingBox? {
        let coordinates = result.features.filter { $0.type != .water }.flatMap(\.polygon)
            + result.centerlines.flatMap(\.coordinates)
        guard let features = BoundingBox(containing: coordinates) else { return nil }
        let latMargin = marginMeters / 111_320.0
        let lonMargin = marginMeters / (111_320.0 * cos((features.south + features.north) / 2 * .pi / 180))
        let grown = BoundingBox(
            south: min(bbox.south, features.south - latMargin),
            west: min(bbox.west, features.west - lonMargin),
            north: max(bbox.north, features.north + latMargin),
            east: max(bbox.east, features.east + lonMargin)
        )
        let latGrowth = max(bbox.south - grown.south, grown.north - bbox.north) * 111_320.0
        let lonGrowth = max(bbox.west - grown.west, grown.east - bbox.east) * 111_320.0 * cos((bbox.south + bbox.north) / 2 * .pi / 180)
        guard max(latGrowth, lonGrowth) > minimumGrowthMeters, grown.spanMeters <= maximumSearchSpanMeters else { return nil }
        return grown
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func buildQuery(bbox: BoundingBox) -> String {
        let b = "\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)"
        return """
        [out:json][timeout:30];
        (
          way["golf"](\(b));
          relation["golf"](\(b));
          way["leisure"="golf_course"](\(b));
          relation["leisure"="golf_course"](\(b));
          way["natural"="water"](\(b));
          relation["natural"="water"](\(b));
          way["natural"="sand"](\(b));
          relation["natural"="sand"](\(b));
        );
        out geom meta;
        """
    }

    static func buildQuery(wayIDs: [Int]) -> String {
        """
        [out:json][timeout:30];
        way(id:\(wayIDs.map(String.init).joined(separator: ",")));
        out geom meta;
        """
    }

    static func boundingBox(around center: Coordinate, radiusMeters: Double) -> BoundingBox {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * cos(center.lat * .pi / 180))
        return BoundingBox(
            south: center.lat - latDelta,
            west: center.lon - lonDelta,
            north: center.lat + latDelta,
            east: center.lon + lonDelta
        )
    }

    func fetchFeatures(bbox: BoundingBox) async throws -> ParsedResult {
        logger.info("Overpass query bbox: \(bbox.south, privacy: .public),\(bbox.west, privacy: .public),\(bbox.north, privacy: .public),\(bbox.east, privacy: .public)")
        return try await run(Self.buildQuery(bbox: bbox))
    }

    /// The ways with the given IDs, wherever they are.
    func fetchWays(ids: [Int]) async throws -> ParsedResult {
        logger.info("Overpass query for \(ids.count, privacy: .public) ways")
        return try await run(Self.buildQuery(wayIDs: ids))
    }

    private func run(_ query: String) async throws -> ParsedResult {
        let maxRetries = 3
        for attempt in 1...maxRetries {
            var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
            request.httpMethod = "POST"
            request.httpBody = query.data(using: .utf8)

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Overpass HTTP status: \(statusCode, privacy: .public) (attempt \(attempt, privacy: .public))")

            if statusCode == 429 {
                if attempt < maxRetries {
                    logger.info("Rate limited, waiting before retry...")
                    try await Task.sleep(for: .seconds(attempt * 5))
                    continue
                }
                throw OverpassError.rateLimited
            }

            if statusCode >= 500 {
                if attempt < maxRetries {
                    logger.info("Server error \(statusCode, privacy: .public), retrying...")
                    try await Task.sleep(for: .seconds(attempt * 2))
                    continue
                }
                throw OverpassError.serverError(statusCode: statusCode)
            }

            if statusCode != 200 {
                throw OverpassError.serverError(statusCode: statusCode)
            }

            logger.info("Overpass response size: \(data.count, privacy: .public) bytes")
            let result = try Self.parseResponse(data: data)
            logger.info("Parsed: \(result.features.count, privacy: .public) features, \(result.centerlines.count, privacy: .public) centerlines, boundary: \(result.courseBoundary != nil, privacy: .public)")
            return result
        }

        throw OverpassError.serverError(statusCode: 0)
    }

    /// Parses Overpass API responses in both formats:
    /// - `out geom;` (inline geometry on ways/relations)
    /// - `out body; >; out skel qt;` (node-reference format with separate node elements)
    static func parseResponse(data: Data) throws -> ParsedResult {
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let elements = json["elements"] as? [[String: Any]] ?? []

        // Build node lookup for node-reference format (out body; >; out skel qt;)
        var nodeLookup: [Int: Coordinate] = [:]
        // Build way geometry lookup for resolving relation members in node-reference format
        var wayGeometry: [Int: [Coordinate]] = [:]

        for element in elements {
            let type = element["type"] as? String ?? ""
            if type == "node",
               let id = element["id"] as? Int,
               let lat = element["lat"] as? Double,
               let lon = element["lon"] as? Double {
                nodeLookup[id] = Coordinate(lat: lat, lon: lon)
            }
        }

        // Second pass: resolve way geometries for relation member lookup
        for element in elements {
            let type = element["type"] as? String ?? ""
            if type == "way",
               let id = element["id"] as? Int,
               let nodeIDs = element["nodes"] as? [Int] {
                let coords = nodeIDs.compactMap { nodeLookup[$0] }
                if !coords.isEmpty {
                    wayGeometry[id] = coords
                }
            }
        }

        var features: [ParsedFeature] = []
        var centerlines: [ParsedCenterline] = []
        var courseBoundary: [Coordinate]?

        for element in elements {
            guard let rawTags = element["tags"] as? [String: Any] else {
                continue
            }
            let tags = rawTags.mapValues { "\($0)" }

            let coords = extractCoordinates(from: element, nodeLookup: nodeLookup, wayGeometry: wayGeometry)
            guard !coords.isEmpty else { continue }
            let osmID = osmID(of: element)
            let version = element["version"] as? Int
            let members = members(of: element)

            if let golfTag = tags["golf"] {
                switch golfTag {
                case "fairway":
                    features.append(ParsedFeature(type: .fairway, polygon: coords, osmID: osmID, version: version, tags: tags, members: members))
                case "green":
                    features.append(ParsedFeature(type: .green, polygon: coords, osmID: osmID, version: version, tags: tags, members: members))
                case "tee":
                    features.append(ParsedFeature(type: .tee, polygon: coords, osmID: osmID, version: version, tags: tags, members: members))
                case "bunker":
                    features.append(ParsedFeature(type: .bunker, polygon: coords, osmID: osmID, version: version, tags: tags, members: members))
                case "water_hazard", "lateral_water_hazard":
                    features.append(ParsedFeature(type: .water, polygon: coords, osmID: osmID, version: version, tags: tags, members: members))
                case "hole":
                    let ref = tags["ref"]
                    let holeNumber = ref.flatMap { Int($0) }
                    centerlines.append(ParsedCenterline(holeNumber: holeNumber, coordinates: coords, osmID: osmID, version: version, tags: tags))
                default:
                    break
                }
            } else if tags["natural"] == "water" {
                features.append(ParsedFeature(type: .water, polygon: coords, osmID: osmID, version: version, tags: tags, members: members))
            } else if tags["natural"] == "sand" {
                // Some mappers tag a bunker only as sand. Publishing adds `golf=bunker`.
                features.append(ParsedFeature(type: .bunker, polygon: coords, osmID: osmID, version: version, tags: tags, members: members))
            }

            if isCourseBoundary(tags: tags) {
                courseBoundary = coords
            }
        }

        return ParsedResult(features: features, centerlines: centerlines, courseBoundary: courseBoundary)
    }

    /// The element's ID in short form: `n`, `w`, or `r` for a node, way, or relation, followed
    /// by its ID, such as `w123456789`. Returns nil when the type or ID is missing.
    static func osmID(of element: [String: Any]) -> String? {
        guard let id = element["id"] as? Int else { return nil }
        switch element["type"] as? String {
        case "node": return "n\(id)"
        case "way": return "w\(id)"
        case "relation": return "r\(id)"
        default: return nil
        }
    }

    /// A relation's members, from an Overpass or OSM API element. Nil for an element that is not
    /// a relation.
    static func members(of element: [String: Any]) -> [OSMRelation.Member]? {
        guard element["type"] as? String == "relation", let members = element["members"] as? [[String: Any]] else { return nil }
        return members.compactMap { member in
            guard let type = member["type"] as? String, let ref = member["ref"] as? Int else { return nil }
            return OSMRelation.Member(type: type, ref: ref, role: member["role"] as? String ?? "")
        }
    }

    /// A course outline is tagged `leisure=golf_course`. Some mappers put that tag on the
    /// clubhouse building as well, which must not be mistaken for the outline.
    static func isCourseBoundary(tags: [String: String]) -> Bool {
        tags["leisure"] == "golf_course"
            && tags["golf"] != "clubhouse"
            && tags["building"] == nil
    }

    /// Extract coordinates from a way or relation, supporting both inline geometry (`out geom;`)
    /// and node-reference format (`out body; >; out skel qt;`).
    private static func extractCoordinates(
        from element: [String: Any],
        nodeLookup: [Int: Coordinate],
        wayGeometry: [Int: [Coordinate]]
    ) -> [Coordinate] {
        // Way with inline geometry (out geom;)
        if let geometry = element["geometry"] as? [[String: Any]] {
            return parseGeometryArray(geometry)
        }

        // Way with node references (out body; >; out skel qt;)
        if let nodeIDs = element["nodes"] as? [Int] {
            return nodeIDs.compactMap { nodeLookup[$0] }
        }

        // Relation with members
        if let members = element["members"] as? [[String: Any]] {
            var coords: [Coordinate] = []
            for member in members {
                let role = member["role"] as? String ?? ""
                guard role == "outer" else { continue }

                // Inline geometry (out geom;)
                if let geometry = member["geometry"] as? [[String: Any]] {
                    coords.append(contentsOf: parseGeometryArray(geometry))
                }
                // Node-reference format: resolve member way ref
                else if let ref = member["ref"] as? Int, let wayCoords = wayGeometry[ref] {
                    coords.append(contentsOf: wayCoords)
                }
            }
            return coords
        }

        return []
    }

    private static func parseGeometryArray(_ geometry: [[String: Any]]) -> [Coordinate] {
        geometry.compactMap { point in
            guard let lat = point["lat"] as? Double,
                  let lon = point["lon"] as? Double else { return nil }
            return Coordinate(lat: lat, lon: lon)
        }
    }
}

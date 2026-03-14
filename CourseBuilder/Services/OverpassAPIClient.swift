import Foundation
import os

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
    }

    struct ParsedResult {
        let features: [ParsedFeature]
        let centerlines: [ParsedCenterline]
        let courseBoundary: [Coordinate]?
    }

    struct ParsedFeature {
        let type: FeatureType
        let polygon: [Coordinate]
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
        );
        out geom;
        """
    }

    static func boundingBox(around center: Coordinate, radiusMeters: Double) -> BoundingBox {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * cos(center.latitude * .pi / 180))
        return BoundingBox(
            south: center.latitude - latDelta,
            west: center.longitude - lonDelta,
            north: center.latitude + latDelta,
            east: center.longitude + lonDelta
        )
    }

    func fetchFeatures(bbox: BoundingBox) async throws -> ParsedResult {
        let query = Self.buildQuery(bbox: bbox)
        logger.info("Overpass query bbox: \(bbox.south, privacy: .public),\(bbox.west, privacy: .public),\(bbox.north, privacy: .public),\(bbox.east, privacy: .public)")

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
                nodeLookup[id] = Coordinate(latitude: lat, longitude: lon)
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

            if let golfTag = tags["golf"] {
                switch golfTag {
                case "fairway":
                    features.append(ParsedFeature(type: .fairway, polygon: coords))
                case "green":
                    features.append(ParsedFeature(type: .green, polygon: coords))
                case "tee":
                    features.append(ParsedFeature(type: .tee, polygon: coords))
                case "bunker":
                    features.append(ParsedFeature(type: .bunker, polygon: coords))
                case "water_hazard", "lateral_water_hazard":
                    features.append(ParsedFeature(type: .water, polygon: coords))
                case "rough":
                    features.append(ParsedFeature(type: .rough, polygon: coords))
                case "hole":
                    let ref = tags["ref"]
                    let holeNumber = ref.flatMap { Int($0) }
                    centerlines.append(ParsedCenterline(holeNumber: holeNumber, coordinates: coords))
                default:
                    break
                }
            } else if tags["natural"] == "water" {
                features.append(ParsedFeature(type: .water, polygon: coords))
            }

            if tags["leisure"] == "golf_course" {
                courseBoundary = coords
            }
        }

        return ParsedResult(features: features, centerlines: centerlines, courseBoundary: courseBoundary)
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
            return Coordinate(latitude: lat, longitude: lon)
        }
    }
}

import Foundation
import os

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "OverpassAPI")

actor OverpassAPIClient {
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
          way["golf"="fairway"](\(b));
          way["golf"="green"](\(b));
          way["golf"="tee"](\(b));
          way["golf"="bunker"](\(b));
          way["golf"="water_hazard"](\(b));
          way["golf"="lateral_water_hazard"](\(b));
          way["golf"="rough"](\(b));
          way["golf"="hole"](\(b));
          way["leisure"="golf_course"](\(b));
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
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.httpBody = query.data(using: .utf8)
        logger.debug("Overpass query for bbox: \(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)")
        let (data, _) = try await session.data(for: request)
        return try Self.parseResponse(data: data)
    }

    static func parseResponse(data: Data) throws -> ParsedResult {
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let elements = json["elements"] as? [[String: Any]] ?? []

        var features: [ParsedFeature] = []
        var centerlines: [ParsedCenterline] = []
        var courseBoundary: [Coordinate]?

        for element in elements {
            guard let tags = element["tags"] as? [String: String],
                  let geometry = element["geometry"] as? [[String: Double]] else {
                continue
            }

            let coords = geometry.compactMap { point -> Coordinate? in
                guard let lat = point["lat"], let lon = point["lon"] else { return nil }
                return Coordinate(latitude: lat, longitude: lon)
            }

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
            }

            if tags["leisure"] == "golf_course" {
                courseBoundary = coords
            }
        }

        return ParsedResult(features: features, centerlines: centerlines, courseBoundary: courseBoundary)
    }
}

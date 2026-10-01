import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "USGSElevation")

/// Looks up elevations from the USGS 3DEP elevation service (US only, 1 m lidar where available).
actor USGSElevationClient {
    enum ElevationError: LocalizedError {
        case serverError(statusCode: Int)
        case invalidResponse
        case requestRejected(message: String)
        case noData(missing: Int, total: Int)

        var errorDescription: String? {
            switch self {
            case .serverError(let code):
                "USGS elevation service returned HTTP \(code). Try again in a moment."
            case .invalidResponse:
                "USGS elevation service returned an unexpected response."
            case .requestRejected(let message):
                "USGS rejected the elevation request: \(message) This usually means the points are outside the United States."
            case .noData(let missing, let total):
                "USGS has no elevation data for \(missing) of \(total) points. USGS only covers the United States."
            }
        }

        /// Whether USGS has no data for any of the requested points, which means they are outside the United States.
        var isOutsideUnitedStates: Bool {
            switch self {
            case .requestRejected:
                true
            case .noData(let missing, let total):
                missing == total
            case .serverError, .invalidResponse:
                false
            }
        }
    }

    static let endpoint = URL(string: "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/getSamples")!
    static let batchSize = 200

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns the elevation in meters (rounded to centimeters) for each coordinate, in order.
    /// An entry is `nil` where USGS has no data for that point.
    func elevations(
        for coordinates: [Coordinate],
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [Double?] {
        var results: [Double?] = []
        results.reserveCapacity(coordinates.count)
        for start in stride(from: 0, to: coordinates.count, by: Self.batchSize) {
            let batch = Array(coordinates[start..<min(start + Self.batchSize, coordinates.count)])
            results.append(contentsOf: try await fetchBatch(batch))
            progress?(results.count, coordinates.count)
        }
        return results
    }

    private func fetchBatch(_ coordinates: [Coordinate]) async throws -> [Double?] {
        let request = Self.buildRequest(for: coordinates)

        // The service often answers the first call with a 504, so retry server errors and timeouts.
        let maxRetries = 4
        for attempt in 1...maxRetries {
            let data: Data
            let statusCode: Int
            do {
                let (body, response) = try await session.data(for: request)
                data = body
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch let error as URLError where error.code == .timedOut && attempt < maxRetries {
                logger.info("USGS request timed out, retrying (attempt \(attempt, privacy: .public))")
                continue
            }
            logger.info("USGS HTTP status: \(statusCode, privacy: .public) (attempt \(attempt, privacy: .public))")

            if statusCode >= 500 {
                if attempt < maxRetries {
                    try await Task.sleep(for: .seconds(attempt * 2))
                    continue
                }
                throw ElevationError.serverError(statusCode: statusCode)
            }

            if statusCode != 200 {
                throw ElevationError.serverError(statusCode: statusCode)
            }

            return try Self.parseResponse(data: data, count: coordinates.count)
        }

        throw ElevationError.serverError(statusCode: 0)
    }

    static func buildRequest(for coordinates: [Coordinate]) -> URLRequest {
        let geometry: [String: Any] = [
            "points": coordinates.map { [$0.longitude, $0.latitude] },
            "spatialReference": ["wkid": 4326],
        ]
        let geometryJSON = String(data: try! JSONSerialization.data(withJSONObject: geometry), encoding: .utf8)!

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "geometry", value: geometryJSON),
            URLQueryItem(name: "geometryType", value: "esriGeometryMultipoint"),
            URLQueryItem(name: "returnFirstValueOnly", value: "true"),
            URLQueryItem(name: "f", value: "json"),
        ]
        // URLComponents leaves "+" unescaped, which a form body would read as a space.
        let body = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    /// Parses a `getSamples` response into one entry per requested point.
    ///
    /// The service leaves out points it has no data for, so samples are matched to the
    /// request by `locationId` (the index of the point in the request), not by position.
    static func parseResponse(data: Data, count: Int) throws -> [Double?] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElevationError.invalidResponse
        }
        // The service answers HTTP 200 with an error body when every point is outside its coverage.
        if let error = json["error"] as? [String: Any] {
            throw ElevationError.requestRejected(message: error["message"] as? String ?? "Unknown error.")
        }
        guard let samples = json["samples"] as? [[String: Any]] else {
            throw ElevationError.invalidResponse
        }

        var results = [Double?](repeating: nil, count: count)
        for sample in samples {
            guard let index = sample["locationId"] as? Int, results.indices.contains(index),
                  let text = sample["value"] as? String, let value = Double(text) else { continue }
            results[index] = (value * 100).rounded() / 100
        }
        return results
    }
}

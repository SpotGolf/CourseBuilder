import CoreGraphics
import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "NAIPImagery")

/// Fetches USDA NAIP aerial imagery (public domain) through the Microsoft Planetary Computer
/// tile API. Tiles are cached on disk by year, since a year's imagery never changes.
actor NAIPImageryClient {
    typealias BoundingBox = OverpassAPIClient.BoundingBox

    enum NAIPError: LocalizedError {
        case noCoverage
        case serverError(statusCode: Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noCoverage: "No NAIP imagery here."
            case .serverError(let code): "NAIP imagery server returned HTTP \(code). Try again in a moment."
            case .badResponse: "NAIP imagery server sent an unexpected response."
            }
        }
    }

    /// One registered mosaic of a single NAIP year.
    struct Imagery: Equatable {
        let searchID: String
        let year: Int
        let gsd: Double
        let box: BoundingBox

        /// Tile zoom whose pixels are about the size of the imagery's pixels.
        var zoom: Int { NAIPImageryClient.zoom(forGSD: gsd) }
    }

    struct TileKey: Hashable {
        let x: Int
        let y: Int
    }

    static let searchURL = URL(string: "https://planetarycomputer.microsoft.com/api/stac/v1/search")!
    static let registerURL = URL(string: "https://planetarycomputer.microsoft.com/api/data/v1/mosaic/register")!
    /// Tiles in one patch. Above this the zoom drops by one.
    static let maxTiles = 64
    static let maxConcurrentRequests = 8
    /// Padding added around a requested area when registering a mosaic, so nearby clicks reuse it.
    static let registrationPadding = 0.01

    private let session: URLSession
    private let cacheDirectory: URL?
    private var registered: [Imagery] = []
    /// Registrations in progress, so map tiles that load together share one.
    private var registering: [(box: BoundingBox, task: Task<Imagery, Error>)] = []
    /// Padded areas found to have no NAIP imagery.
    private var uncovered: [BoundingBox] = []

    init(session: URLSession = .shared, cacheDirectory: URL? = NAIPImageryClient.defaultCacheDirectory) {
        self.session = session
        self.cacheDirectory = cacheDirectory
    }

    static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CourseBuilder/naip", isDirectory: true)
    }

    // MARK: - Public

    /// Fetches a patch of the newest NAIP imagery covering the box.
    func patch(covering box: BoundingBox) async throws -> (patch: ImagePatch, imagery: Imagery) {
        let imagery = try await imagery(for: box)
        let center = Coordinate(lat: (box.south + box.north) / 2, lon: (box.west + box.east) / 2)
        let offset = NAD83.offset(near: center)
        // Tiles are placed by NAD83 coordinates, so pick them for the box shifted into NAD83.
        let tileBox = BoundingBox(
            south: box.south + offset.latitude,
            west: box.west + offset.longitude,
            north: box.north + offset.latitude,
            east: box.east + offset.longitude
        )
        let range = Self.tileRange(for: tileBox, zoom: imagery.zoom)
        var patch = ImagePatch(
            zoom: range.zoom,
            originX: range.minX * WebMercator.tileSize,
            originY: range.minY * WebMercator.tileSize,
            width: (range.maxX - range.minX + 1) * WebMercator.tileSize,
            height: (range.maxY - range.minY + 1) * WebMercator.tileSize
        )
        patch.datumOffset = offset

        var keys: [TileKey] = []
        for y in range.minY...range.maxY {
            for x in range.minX...range.maxX {
                keys.append(TileKey(x: x, y: y))
            }
        }

        let tiles = try await fetchTiles(keys, zoom: range.zoom, imagery: imagery)
        for key in keys {
            let tile = tiles[key]
            patch.place(rgbTile: tile?.rgb, falseColorTile: tile?.falseColor, tileX: key.x, tileY: key.y)
        }
        guard patch.valid.contains(true) else { throw NAIPError.noCoverage }
        return (patch, imagery)
    }

    /// One RGB map tile of the newest NAIP imagery around it, or nil where there is none.
    /// Tiles are placed by NAD83 coordinates; see `NAD83`.
    func mapTile(zoom: Int, x: Int, y: Int) async throws -> CGImage? {
        let size = CGFloat(WebMercator.tileSize)
        let northWest = WebMercator.coordinate(forPixel: CGPoint(x: CGFloat(x) * size, y: CGFloat(y) * size), zoom: zoom)
        let southEast = WebMercator.coordinate(forPixel: CGPoint(x: CGFloat(x + 1) * size, y: CGFloat(y + 1) * size), zoom: zoom)
        let box = BoundingBox(south: southEast.lat, west: northWest.lon, north: northWest.lat, east: southEast.lon)
        let imagery: Imagery
        do {
            imagery = try await self.imagery(for: box)
        } catch NAIPError.noCoverage {
            return nil
        }
        return try await tileImage(TileKey(x: x, y: y), zoom: zoom, imagery: imagery, bands: .rgb)
    }

    // MARK: - Imagery Lookup

    private func imagery(for box: BoundingBox) async throws -> Imagery {
        if let existing = registered.first(where: { $0.box.contains(box) }) {
            return existing
        }
        if uncovered.contains(where: { $0.contains(box) }) {
            throw NAIPError.noCoverage
        }
        if let pending = registering.first(where: { $0.box.contains(box) }) {
            return try await pending.task.value
        }
        let padded = BoundingBox(
            south: box.south - Self.registrationPadding,
            west: box.west - Self.registrationPadding,
            north: box.north + Self.registrationPadding,
            east: box.east + Self.registrationPadding
        )
        let task = Task { try await self.register(padded) }
        registering.append((padded, task))
        defer { registering.removeAll { $0.box == padded } }
        do {
            let imagery = try await task.value
            registered.append(imagery)
            return imagery
        } catch NAIPError.noCoverage {
            uncovered.append(padded)
            throw NAIPError.noCoverage
        }
    }

    private func register(_ padded: BoundingBox) async throws -> Imagery {
        let searchData = try await send(Self.buildSearchRequest(for: padded))
        guard let newest = try Self.parseNewestYear(data: searchData) else { throw NAIPError.noCoverage }
        let registerData = try await send(Self.buildRegisterRequest(for: padded, year: newest.year))
        let searchID = try Self.parseSearchID(data: registerData)
        logger.info("Registered NAIP \(newest.year) mosaic (gsd \(newest.gsd) m)")
        return Imagery(searchID: searchID, year: newest.year, gsd: newest.gsd, box: padded)
    }

    static func buildSearchRequest(for box: BoundingBox) -> URLRequest {
        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "collections": ["naip"],
            "bbox": [box.west, box.south, box.east, box.north],
            "limit": 100,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func buildRegisterRequest(for box: BoundingBox, year: Int) -> URLRequest {
        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "collections": ["naip"],
            "bbox": [box.west, box.south, box.east, box.north],
            "filter-lang": "cql2-json",
            "filter": [
                "op": "anyinteracts",
                "args": [
                    ["property": "datetime"],
                    ["interval": ["\(year)-01-01T00:00:00Z", "\(year)-12-31T23:59:59Z"]],
                ],
            ] as [String: Any],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The newest year in a STAC search response, and the coarsest pixel size flown that year.
    static func parseNewestYear(data: Data) throws -> (year: Int, gsd: Double)? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { throw NAIPError.badResponse }
        var gsdByYear: [Int: Double] = [:]
        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let datetime = properties["datetime"] as? String,
                  let year = Int(datetime.prefix(4)) else { continue }
            let gsd = (properties["gsd"] as? Double) ?? 1.0
            gsdByYear[year] = max(gsdByYear[year] ?? 0, gsd)
        }
        guard let year = gsdByYear.keys.max(), let gsd = gsdByYear[year] else { return nil }
        return (year, gsd)
    }

    static func parseSearchID(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["searchid"] as? String else { throw NAIPError.badResponse }
        return id
    }

    // MARK: - Tiles

    static func zoom(forGSD gsd: Double) -> Int {
        switch gsd {
        case ..<0.45: 19
        case ..<0.8: 18
        default: 17
        }
    }

    /// Tiles covering the box. Lowers the zoom until the count is at most `maxTiles`.
    static func tileRange(for box: BoundingBox, zoom: Int) -> (zoom: Int, minX: Int, minY: Int, maxX: Int, maxY: Int) {
        var zoom = zoom
        while true {
            let topLeft = WebMercator.pixel(for: Coordinate(lat: box.north, lon: box.west), zoom: zoom)
            let bottomRight = WebMercator.pixel(for: Coordinate(lat: box.south, lon: box.east), zoom: zoom)
            let size = CGFloat(WebMercator.tileSize)
            let minX = Int((topLeft.x / size).rounded(.down))
            let minY = Int((topLeft.y / size).rounded(.down))
            let maxX = Int((bottomRight.x / size).rounded(.down))
            let maxY = Int((bottomRight.y / size).rounded(.down))
            if (maxX - minX + 1) * (maxY - minY + 1) <= maxTiles || zoom <= 14 {
                return (zoom, minX, minY, maxX, maxY)
            }
            zoom -= 1
        }
    }

    enum Bands: String {
        /// Red, green, blue.
        case rgb = "1,2,3"
        /// Near-infrared, red, green.
        case falseColor = "4,1,2"
    }

    static func tileURL(searchID: String, zoom: Int, x: Int, y: Int, bands: Bands) -> URL {
        var components = URLComponents(string: "https://planetarycomputer.microsoft.com/api/data/v1/mosaic/\(searchID)/tiles/WebMercatorQuad/\(zoom)/\(x)/\(y)")!
        components.queryItems = [
            URLQueryItem(name: "collection", value: "naip"),
            URLQueryItem(name: "assets", value: "image"),
            URLQueryItem(name: "format", value: "png"),
            URLQueryItem(name: "asset_bidx", value: "image|\(bands.rawValue)"),
        ]
        return components.url!
    }

    private struct Tile: Sendable {
        let rgb: CGImage?
        let falseColor: CGImage?
    }

    private func fetchTiles(_ keys: [TileKey], zoom: Int, imagery: Imagery) async throws -> [TileKey: Tile] {
        var result: [TileKey: Tile] = [:]
        try await withThrowingTaskGroup(of: (TileKey, Tile).self) { group in
            var nextIndex = 0
            while nextIndex < keys.count || !group.isEmpty {
                while nextIndex < keys.count, nextIndex - result.count < Self.maxConcurrentRequests {
                    let key = keys[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        async let rgb = self.tileImage(key, zoom: zoom, imagery: imagery, bands: .rgb)
                        async let falseColor = self.tileImage(key, zoom: zoom, imagery: imagery, bands: .falseColor)
                        return (key, Tile(rgb: try await rgb, falseColor: try await falseColor))
                    }
                }
                if let (key, tile) = try await group.next() {
                    result[key] = tile
                }
            }
        }
        return result
    }

    private func tileImage(_ key: TileKey, zoom: Int, imagery: Imagery, bands: Bands) async throws -> CGImage? {
        let cacheFile = cacheDirectory?
            .appendingPathComponent("\(imagery.year)/\(zoom)/\(key.x)", isDirectory: true)
            .appendingPathComponent("\(key.y)-\(bands == .rgb ? "rgb" : "nir").png")

        if let cacheFile, let data = try? Data(contentsOf: cacheFile) {
            return ImagePatch.decodeImage(data)
        }

        let url = Self.tileURL(searchID: imagery.searchID, zoom: zoom, x: key.x, y: key.y, bands: bands)
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The tile server answers 404 for tiles outside the imagery.
        if status == 404 || status == 204 { return nil }
        guard status == 200 else { throw NAIPError.serverError(statusCode: status) }

        if let cacheFile {
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return ImagePatch.decodeImage(data)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NAIPError.serverError(statusCode: status) }
        return data
    }
}

extension OverpassAPIClient.BoundingBox: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.south == rhs.south && lhs.west == rhs.west && lhs.north == rhs.north && lhs.east == rhs.east
    }

    func contains(_ other: Self) -> Bool {
        other.south >= south && other.north <= north && other.west >= west && other.east <= east
    }

    /// Box of the given radius in meters around a coordinate.
    init(around center: Coordinate, radiusMeters: Double) {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * cos(center.lat * .pi / 180))
        self.init(
            south: center.lat - latDelta,
            west: center.lon - lonDelta,
            north: center.lat + latDelta,
            east: center.lon + lonDelta
        )
    }

    func union(_ other: Self) -> Self {
        Self(
            south: min(south, other.south),
            west: min(west, other.west),
            north: max(north, other.north),
            east: max(east, other.east)
        )
    }
}

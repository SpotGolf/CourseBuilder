import CoreGraphics
import Foundation
import CourseDataSwift

/// Fetches Esri World Imagery tiles for auto polygon and Fit to Imagery. The imagery has red,
/// green, and blue only, so detection uses its rules for imagery without near-infrared.
///
/// Esri serves different imagery at different zooms: lower zooms are often older and placed a
/// little differently. The map shows the newest, highest-zoom imagery, so detection uses that
/// zoom too. A large area is fetched at that zoom and shrunk, instead of fetched at a lower zoom.
actor EsriImageryClient {
    typealias BoundingBox = OverpassAPIClient.BoundingBox
    typealias TileRange = (zoom: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)

    enum EsriError: LocalizedError {
        case noCoverage
        case serverError(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .noCoverage: "No Esri imagery here."
            case .serverError(let code): "Esri imagery server returned HTTP \(code). Try again in a moment."
            }
        }
    }

    /// Highest zoom fetched: about 0.12 m per pixel in the continental US.
    static let maxZoom = 20
    static let minZoom = 15
    /// Most tiles fetched for one patch. Above this, a lower zoom is fetched.
    static let maxSourceTiles = 256
    static let maxConcurrentRequests = 8

    private let session: URLSession
    /// Newest zoom with imagery, by zoom-15 tile.
    private var newestZooms: [String: Int] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches a patch of the newest Esri imagery covering the box, at no more than
    /// `NAIPImageryClient.maxTiles` tiles of detail. Esri tiles are placed by WGS84
    /// coordinates, so no datum offset is needed.
    func patch(covering box: BoundingBox) async throws -> ImagePatch {
        let center = Coordinate(lat: (box.south + box.north) / 2, lon: (box.west + box.east) / 2)
        guard let newest = try await newestZoom(at: center) else { throw EsriError.noCoverage }

        let target = NAIPImageryClient.tileRange(for: box, zoom: newest).zoom
        var sourceZoom = newest
        if Self.tileCount(Self.exactRange(for: box, zoom: newest)) > Self.maxSourceTiles {
            sourceZoom = target
        }
        let source = try await fetch(Self.exactRange(for: box, zoom: sourceZoom))
        guard source.valid.contains(true) else { throw EsriError.noCoverage }
        return sourceZoom > target ? source.downsampled(by: 1 << (sourceZoom - target)) : source
    }

    /// The highest zoom, up to `maxZoom`, with imagery at the coordinate.
    private func newestZoom(at coordinate: Coordinate) async throws -> Int? {
        let key = Self.tileKey(for: coordinate, zoom: Self.minZoom)
        if let zoom = newestZooms["\(key.x)-\(key.y)"] { return zoom }
        for zoom in stride(from: Self.maxZoom, through: Self.minZoom, by: -1) {
            let tile = Self.tileKey(for: coordinate, zoom: zoom)
            if try await self.tile(zoom: zoom, x: tile.x, y: tile.y) != nil {
                newestZooms["\(key.x)-\(key.y)"] = zoom
                return zoom
            }
        }
        return nil
    }

    private func fetch(_ range: TileRange) async throws -> ImagePatch {
        var patch = ImagePatch(
            zoom: range.zoom,
            originX: range.minX * WebMercator.tileSize,
            originY: range.minY * WebMercator.tileSize,
            width: (range.maxX - range.minX + 1) * WebMercator.tileSize,
            height: (range.maxY - range.minY + 1) * WebMercator.tileSize
        )
        patch.hasNearInfrared = false

        var keys: [(x: Int, y: Int)] = []
        for y in range.minY...range.maxY {
            for x in range.minX...range.maxX {
                keys.append((x, y))
            }
        }

        try await withThrowingTaskGroup(of: (Int, Int, CGImage?).self) { group in
            var nextIndex = 0
            var running = 0
            while nextIndex < keys.count || running > 0 {
                while nextIndex < keys.count, running < Self.maxConcurrentRequests {
                    let key = keys[nextIndex]
                    nextIndex += 1
                    running += 1
                    group.addTask {
                        (key.x, key.y, try await self.tile(zoom: range.zoom, x: key.x, y: key.y))
                    }
                }
                if let (x, y, image) = try await group.next() {
                    running -= 1
                    patch.place(colorTile: image, tileX: x, tileY: y)
                }
            }
        }
        return patch
    }

    private func tile(zoom: Int, x: Int, y: Int) async throws -> CGImage? {
        let (data, response) = try await session.data(from: ImageryLayer.esriTileURL(zoom: zoom, x: x, y: y))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `blankTile=false` makes the server answer 404 where it has no imagery.
        if status == 404 { return nil }
        guard status == 200 else { throw EsriError.serverError(statusCode: status) }
        return ImagePatch.decodeImage(data)
    }

    // MARK: - Tiles

    static func tileKey(for coordinate: Coordinate, zoom: Int) -> (x: Int, y: Int) {
        let pixel = WebMercator.pixel(for: coordinate, zoom: zoom)
        let size = CGFloat(WebMercator.tileSize)
        return (Int((pixel.x / size).rounded(.down)), Int((pixel.y / size).rounded(.down)))
    }

    /// Tiles covering the box at exactly this zoom.
    static func exactRange(for box: BoundingBox, zoom: Int) -> TileRange {
        let topLeft = tileKey(for: Coordinate(lat: box.north, lon: box.west), zoom: zoom)
        let bottomRight = tileKey(for: Coordinate(lat: box.south, lon: box.east), zoom: zoom)
        return (zoom, topLeft.x, topLeft.y, bottomRight.x, bottomRight.y)
    }

    static func tileCount(_ range: TileRange) -> Int {
        (range.maxX - range.minX + 1) * (range.maxY - range.minY + 1)
    }
}

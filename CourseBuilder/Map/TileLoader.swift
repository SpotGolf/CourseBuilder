import CoreGraphics
import Foundation
import ImageIO
import Observation
import os

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "TileLoader")

struct MapTileKey: Hashable {
    let layer: ImageryLayer
    let zoom: Int
    let x: Int
    let y: Int

    var parent: MapTileKey? {
        guard zoom > 0 else { return nil }
        return MapTileKey(layer: layer, zoom: zoom - 1, x: x >> 1, y: y >> 1)
    }
}

/// Loads and caches imagery tiles for the map view.
///
/// Only the tiles last asked for are loaded, so tiles scrolled past while panning are skipped.
@MainActor
@Observable
final class TileLoader {
    static let maxConcurrentRequests = 8

    /// Changes each time a tile finishes loading, so the map redraws.
    private(set) var revision = 0

    @ObservationIgnored private let images = NSCache<NSString, CGImage>()
    /// Tiles the server has no imagery for.
    @ObservationIgnored private var missing: Set<MapTileKey> = []
    @ObservationIgnored private var inFlight: Set<MapTileKey> = []
    @ObservationIgnored private var queue: [MapTileKey] = []
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let naip: NAIPImageryClient

    init(naip: NAIPImageryClient = NAIPImageryClient()) {
        self.naip = naip
        images.totalCostLimit = 256 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CourseBuilder/tiles", isDirectory: true)
        // Esri tiles say how long they may be kept, so the HTTP cache honors their terms.
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024, directory: cacheDirectory)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration)
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "CourseBuilder/\(version)"
    }

    func image(for key: MapTileKey) -> CGImage? {
        images.object(forKey: Self.cacheKey(key))
    }

    func isMissing(_ key: MapTileKey) -> Bool {
        missing.contains(key)
    }

    /// Replaces the tiles waiting to load with `keys`, in order.
    func load(_ keys: [MapTileKey]) {
        queue = keys.filter { image(for: $0) == nil && !missing.contains($0) && !inFlight.contains($0) }
        pump()
    }

    private func pump() {
        while inFlight.count < Self.maxConcurrentRequests, !queue.isEmpty {
            let key = queue.removeFirst()
            inFlight.insert(key)
            Task {
                let result = await fetch(key)
                finish(key, result)
            }
        }
    }

    private enum FetchResult {
        case image(CGImage)
        case missing
        case failed
    }

    private func finish(_ key: MapTileKey, _ result: FetchResult) {
        inFlight.remove(key)
        switch result {
        case .image(let image):
            images.setObject(image, forKey: Self.cacheKey(key), cost: image.bytesPerRow * image.height)
            revision += 1
        case .missing:
            missing.insert(key)
            revision += 1
        case .failed:
            break
        }
        pump()
    }

    private func fetch(_ key: MapTileKey) async -> FetchResult {
        do {
            switch key.layer {
            case .esri:
                let (data, response) = try await session.data(from: ImageryLayer.esriTileURL(zoom: key.zoom, x: key.x, y: key.y))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 404 { return .missing }
                guard status == 200 else {
                    logger.error("Esri tile \(key.zoom)/\(key.x)/\(key.y) returned HTTP \(status)")
                    return .failed
                }
                return Self.decode(data).map(FetchResult.image) ?? .failed
            case .naip:
                guard let image = try await naip.mapTile(zoom: key.zoom, x: key.x, y: key.y) else { return .missing }
                return .image(image)
            }
        } catch {
            logger.error("Tile \(key.layer.rawValue) \(key.zoom)/\(key.x)/\(key.y) failed: \(error)")
            return .failed
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func cacheKey(_ key: MapTileKey) -> NSString {
        "\(key.layer.rawValue)/\(key.zoom)/\(key.x)/\(key.y)" as NSString
    }
}

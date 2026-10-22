import CoreGraphics
import Foundation
import Observation
import CourseDataSwift

/// One auto polygon or Fit to Imagery preview in progress. Pure logic on a fetched patch,
/// so changes to seeds or tolerance re-run detection without network calls.
struct AutoPolygonSession {
    typealias BoundingBox = OverpassAPIClient.BoundingBox

    enum Mode: Equatable {
        case create(FeatureType)
        case fit(featureID: Int, type: FeatureType, oldPolygon: [Coordinate])

        var type: FeatureType {
            switch self {
            case .create(let type): type
            case .fit(_, let type, _): type
            }
        }
    }

    enum Operation: Equatable {
        /// Add the area around this point.
        case add(Coordinate)
        /// Remove the area around this point.
        case remove(Coordinate)

        var coordinate: Coordinate {
            switch self {
            case .add(let c), .remove(let c): c
            }
        }
    }

    struct Result: Equatable {
        let polygon: [Coordinate]
        let exceedsSafetyLimit: Bool
        /// Fit only: the new area is under 50% or over 200% of the old area.
        let areaDiffersFromOriginal: Bool
    }

    static let toleranceRange: ClosedRange<Double> = 0.5...8
    static let toleranceStep = 0.25
    /// Radius around a click whose colors seed the region.
    static let seedRadiusMeters = 1.5
    /// How far Fit to Imagery shrinks the old polygon to pick seed pixels.
    static let fitSeedInsetMeters = 1.0

    let mode: Mode
    var patch: ImagePatch
    var operations: [Operation]
    var tolerance: Double
    private(set) var result: Result?
    private var cachedValues: PixelValues?

    init(mode: Mode, patch: ImagePatch, operations: [Operation] = [], tolerance: Double? = nil) {
        self.mode = mode
        self.patch = patch
        self.operations = operations
        self.tolerance = tolerance ?? mode.type.segmentationProfile.tolerance
    }

    var type: FeatureType { mode.type }

    /// Area the patch must cover for this mode and these operations.
    static func requiredBox(mode: Mode, operations: [Operation]) -> BoundingBox? {
        let profile = mode.type.segmentationProfile
        var box: BoundingBox?
        if case .fit(_, _, let oldPolygon) = mode, let polygonBox = BoundingBox(containing: oldPolygon) {
            let midLat = (polygonBox.south + polygonBox.north) / 2
            let margin = profile.fitMarginMeters + 5
            let latDelta = margin / 111_320.0
            let lonDelta = margin / (111_320.0 * cos(midLat * .pi / 180))
            box = BoundingBox(
                south: polygonBox.south - latDelta,
                west: polygonBox.west - lonDelta,
                north: polygonBox.north + latDelta,
                east: polygonBox.east + lonDelta
            )
        }
        for operation in operations {
            let around = BoundingBox(around: operation.coordinate, radiusMeters: profile.maxRadiusMeters)
            box = box.map { $0.union(around) } ?? around
        }
        return box
    }

    /// Re-runs detection and updates `result`. `result` is nil when nothing was found.
    mutating func recompute() {
        result = nil
        guard let box = Self.requiredBox(mode: mode, operations: operations) else { return }
        let topLeft = patch.pixel(for: Coordinate(lat: box.north, lon: box.west))
        let bottomRight = patch.pixel(for: Coordinate(lat: box.south, lon: box.east))
        let window = PixelWindow(
            covering: CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y),
            in: patch
        )
        guard window.width > 0, window.height > 0 else { return }

        if cachedValues?.window != window {
            cachedValues = PixelValues(patch: patch, window: window)
        }
        guard let values = cachedValues else { return }

        let profile = type.segmentationProfile
        let metersPerPixel = patch.metersPerPixel
        let width = window.width, height = window.height
        func local(_ coordinate: Coordinate) -> CGPoint {
            let p = patch.pixel(for: coordinate)
            return CGPoint(x: p.x - CGFloat(window.x), y: p.y - CGFloat(window.y))
        }
        func indices(of mask: BinaryMask) -> [Int] {
            mask.bits.indices.filter { mask.bits[$0] }
        }

        var mask = BinaryMask(width: width, height: height)
        var seeds: [Int] = []
        var fitAllowed: BinaryMask?
        // Tolerance above or below the type's default keeps more or fewer pixels when a pixel is
        // judged against its surroundings instead of against the seed colors.
        let bias = Float((tolerance - profile.tolerance) * 2)

        if case .fit(_, _, let oldPolygon) = mode {
            let polygonMask = BinaryMask.polygon(width: width, height: height, points: oldPolygon.map(local))
            var seedMask = polygonMask.eroded(by: Self.fitSeedInsetMeters / metersPerPixel)
            if seedMask.count < 20 { seedMask = polygonMask }
            let allowed = polygonMask.dilated(by: profile.fitMarginMeters / metersPerPixel)
            fitAllowed = allowed
            // An old outline may cover other ground (grass inside a bunker outline). Seed only
            // from pixels that pass the type rule, so they set the colors.
            let insidePixels = indices(of: seedMask)
            let typedPixels = insidePixels.filter {
                values.valid[$0] && profile.accepts(values, at: $0)
            }
            var seedPixels = typedPixels
            if seedPixels.isEmpty {
                // The outline missed the feature (OSM outlines can be several meters off).
                // Seed from matching pixels anywhere in the search area.
                seedPixels = indices(of: allowed).filter {
                    values.valid[$0] && profile.accepts(values, at: $0)
                }
            }
            if profile.refinesFit {
                // The old outline is the starting guess, so the band just outside it is the
                // ground the feature must be told apart from.
                mask = FeatureSegmenter.refine(values: values, mask: polygonMask, allowed: allowed, seeds: seedPixels,
                                               profile: profile, metersPerPixel: metersPerPixel, bias: bias)
                seeds += seedPixels
            } else if let statistics = SeedStatistics(values: values, pixels: seedPixels) {
                mask = FeatureSegmenter.grow(values: values, seeds: seedPixels, statistics: statistics,
                                             tolerance: tolerance, allowed: allowed, profile: profile)
                seeds += seedPixels
            }
        }

        for operation in operations {
            let center = local(operation.coordinate)
            let seedPixels = indices(of: BinaryMask.circle(width: width, height: height, center: center,
                                                           radius: Self.seedRadiusMeters / metersPerPixel))
            guard let statistics = SeedStatistics(values: values, pixels: seedPixels) else { continue }
            switch operation {
            case .add:
                let allowed = fitAllowed ?? BinaryMask.circle(width: width, height: height, center: center,
                                                              radius: profile.maxRadiusMeters / metersPerPixel)
                var grown = FeatureSegmenter.grow(values: values, seeds: seedPixels, statistics: statistics,
                                                  tolerance: tolerance, allowed: allowed, profile: profile)
                if profile.splitsGrownRegion {
                    let cleanedGrown = FeatureSegmenter.cleanUp(grown, metersPerPixel: metersPerPixel, seeds: seedPixels)
                    grown = FeatureSegmenter.splitFromSurroundings(values: values, mask: cleanedGrown, seeds: seedPixels,
                                                                   metersPerPixel: metersPerPixel, bias: bias)
                }
                mask = mask.union(grown)
                seeds += seedPixels
            case .remove:
                // Removal grows from the click through matching pixels of the current result only.
                let removeProfile = SegmentationProfile(
                    tolerance: profile.tolerance, maxRadiusMeters: profile.maxRadiusMeters,
                    fitMarginMeters: profile.fitMarginMeters, errorLimitMeters: profile.errorLimitMeters,
                    minSpacingMeters: profile.minSpacingMeters, safetyLimit: profile.safetyLimit,
                    refinesFit: false, splitsGrownRegion: false, accepts: { _, _ in true },
                    acceptsWithoutNearInfrared: { _, _ in true }
                )
                let grown = FeatureSegmenter.grow(values: values, seeds: seedPixels, statistics: statistics,
                                                  tolerance: tolerance, allowed: mask, profile: removeProfile)
                mask = mask.subtracting(grown)
                let removed = Set(indices(of: grown))
                seeds.removeAll { removed.contains($0) }
            }
        }

        let cleaned = FeatureSegmenter.cleanUp(mask, metersPerPixel: metersPerPixel, seeds: seeds)
        guard !cleaned.isEmpty else { return }
        let ring = OutlineTracer.traceBoundary(cleaned)
        let reduced = OutlineTracer.reducePoints(ring, type: type, metersPerPixel: metersPerPixel)
        guard reduced.points.count >= 3 else { return }

        let polygon = reduced.points.map {
            patch.coordinate(forPixel: CGPoint(x: $0.x + CGFloat(window.x), y: $0.y + CGFloat(window.y)))
        }
        var areaDiffers = false
        if case .fit(_, _, let oldPolygon) = mode {
            let oldArea = abs(PolygonGeometry.area(of: oldPolygon))
            let newArea = abs(PolygonGeometry.area(of: polygon))
            if oldArea > 0 {
                let ratio = newArea / oldArea
                areaDiffers = ratio < 0.5 || ratio > 2
            }
        }
        result = Result(polygon: polygon, exceedsSafetyLimit: reduced.exceedsSafetyLimit,
                        areaDiffersFromOriginal: areaDiffers)
    }
}

/// Runs auto polygon and Fit to Imagery previews for the map editor: fetches imagery from the
/// layer shown on the map when needed and runs detection off the main thread.
@MainActor
@Observable
final class AutoPolygonController {
    private(set) var session: AutoPolygonSession?
    private(set) var isLoading = false
    /// Error or "nothing found" message for the status bar.
    private(set) var message: String?
    /// NAIP only: the year of the imagery used.
    private(set) var imageryYear: Int?
    /// The imagery the current preview is traced from.
    private(set) var layer: ImageryLayer = .naip

    @ObservationIgnored private let client: NAIPImageryClient
    @ObservationIgnored private let esriClient: EsriImageryClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// What the user asked for most recently; applied when the current work finishes.
    @ObservationIgnored private var pendingMode: AutoPolygonSession.Mode?

    init(client: NAIPImageryClient = NAIPImageryClient(), esriClient: EsriImageryClient = EsriImageryClient()) {
        self.client = client
        self.esriClient = esriClient
    }

    var isActive: Bool { session != nil || isLoading }
    var mode: AutoPolygonSession.Mode? { session?.mode ?? pendingMode }
    var result: AutoPolygonSession.Result? { session?.result }
    var tolerance: Double? { session?.tolerance }

    /// Starts a new auto polygon preview from a click, traced from the given imagery.
    func startCreate(type: FeatureType, at coordinate: Coordinate, layer: ImageryLayer) {
        useLayer(layer)
        run(mode: .create(type), operations: [.add(coordinate)], tolerance: nil)
    }

    /// Starts a Fit to Imagery preview for a feature, traced from the given imagery.
    func startFit(feature: Feature, layer: ImageryLayer) {
        useLayer(layer)
        run(mode: .fit(featureID: feature.id, type: feature.type, oldPolygon: Array(feature.polygon)), operations: [], tolerance: nil)
    }

    /// Switches imagery. A preview from other imagery can't be reused, since its pixels differ.
    private func useLayer(_ layer: ImageryLayer) {
        guard layer != self.layer else { return }
        self.layer = layer
        session = nil
        imageryYear = nil
    }

    func add(at coordinate: Coordinate) {
        guard let session else { return }
        run(mode: session.mode, operations: session.operations + [.add(coordinate)], tolerance: session.tolerance)
    }

    func remove(at coordinate: Coordinate) {
        guard let session else { return }
        run(mode: session.mode, operations: session.operations + [.remove(coordinate)], tolerance: session.tolerance)
    }

    func adjustTolerance(by steps: Int) {
        guard let session else { return }
        let range = AutoPolygonSession.toleranceRange
        let tolerance = min(range.upperBound, max(range.lowerBound, session.tolerance + Double(steps) * AutoPolygonSession.toleranceStep))
        guard tolerance != session.tolerance else { return }
        run(mode: session.mode, operations: session.operations, tolerance: tolerance)
    }

    func cancel() {
        task?.cancel()
        generation += 1
        session = nil
        pendingMode = nil
        isLoading = false
        message = nil
    }

    private func run(mode: AutoPolygonSession.Mode, operations: [AutoPolygonSession.Operation], tolerance: Double?) {
        guard let box = AutoPolygonSession.requiredBox(mode: mode, operations: operations) else { return }
        task?.cancel()
        generation += 1
        let current = generation
        // Reusing the previous session keeps its cached pixel values.
        let previous = session?.mode == mode ? session : nil
        pendingMode = mode
        isLoading = true
        message = nil

        task = Task { [client, esriClient, layer] in
            do {
                var start = previous
                if start.map({ !$0.patch.contains(box) }) ?? true {
                    switch layer {
                    case .naip:
                        let fetched = try await client.patch(covering: box)
                        start = AutoPolygonSession(mode: mode, patch: fetched.patch)
                        if current == self.generation { self.imageryYear = fetched.imagery.year }
                    case .esri:
                        start = AutoPolygonSession(mode: mode, patch: try await esriClient.patch(covering: box))
                    }
                }
                guard var session = start, !Task.isCancelled else { return }
                session.operations = operations
                session.tolerance = tolerance ?? mode.type.segmentationProfile.tolerance
                let computed = await Task.detached(priority: .userInitiated) { [session] in
                    var session = session
                    session.recompute()
                    return session
                }.value
                guard current == self.generation else { return }
                self.session = computed
                self.isLoading = false
                if computed.result == nil {
                    self.message = "Nothing found here. Press ] to raise the tolerance or click another spot."
                }
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.isLoading = false
                self.message = error.localizedDescription
            }
        }
    }
}

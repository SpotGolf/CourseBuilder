import AppKit
import SwiftUI
import CourseDataSwift

/// A map of imagery tiles with drawn content on top.
///
/// Drag or two-finger scroll to pan. Pinch, scroll a mouse wheel, or use the buttons to zoom.
/// `content` is drawn above the imagery and should place itself with `camera.projection`.
struct TileMapView<Content: View>: View {
    let camera: MapCamera
    let loader: TileLoader
    let layer: ImageryLayer
    /// False while something on the map (such as a vertex) is being dragged.
    var panEnabled = true
    @ViewBuilder let content: () -> Content

    @State private var lastTranslation: CGSize = .zero
    @State private var magnifyStartZoom: Double?
    @State private var scrollMonitor: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {
            TileLayerView(camera: camera, loader: loader, layer: layer)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color.black)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { camera.size = $0 }
        .gesture(panGesture, including: panEnabled ? .all : .subviews)
        .simultaneousGesture(magnifyGesture)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                camera.hoveredPoint = location
                camera.hoveredCoordinate = camera.projection.coordinate(at: location)
            case .ended:
                camera.hoveredPoint = nil
                camera.hoveredCoordinate = nil
            }
        }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                zoomButtons
                attribution
            }
            .padding(8)
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                camera.pan(by: CGSize(
                    width: value.translation.width - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height
                ))
                lastTranslation = value.translation
            }
            .onEnded { _ in
                lastTranslation = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnifyStartZoom ?? camera.zoom
                magnifyStartZoom = start
                camera.setZoom(start + log2(value.magnification), anchor: value.startLocation)
            }
            .onEnded { _ in
                magnifyStartZoom = nil
            }
    }

    /// Two-finger trackpad scrolling pans; a mouse wheel zooms around the mouse.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let camera = camera
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                guard let point = camera.hoveredPoint else { return event }
                if event.hasPreciseScrollingDeltas {
                    camera.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                } else if event.scrollingDeltaY != 0 {
                    camera.setZoom(camera.zoom + (event.scrollingDeltaY > 0 ? 0.5 : -0.5), anchor: point)
                }
                camera.hoveredCoordinate = camera.projection.coordinate(at: point)
                return nil
            }
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }

    // MARK: - Controls

    private var zoomButtons: some View {
        // Plain buttons only take clicks on drawn pixels, so the thin minus sign needs a
        // content shape to be clickable across the whole button.
        VStack(spacing: 0) {
            Button {
                camera.zoomIn()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            Divider().frame(width: 24)
            Button {
                camera.zoomOut()
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var attribution: some View {
        HStack(spacing: 6) {
            Text(layer.attribution)
            Link(layer.termsLabel, destination: layer.termsURL)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Draws the imagery tiles for the camera and asks the loader for the ones it lacks.
private struct TileLayerView: View {
    let camera: MapCamera
    let loader: TileLoader
    let layer: ImageryLayer
    @Environment(\.displayScale) private var displayScale

    /// Ancestors searched for a stand-in while a tile loads or where it has no imagery.
    private static let fallbackLevels = 6

    var body: some View {
        let plan = TilePlan(projection: camera.projection, layer: layer, displayScale: displayScale, shift: datumShift)
        // Redraw when a tile arrives.
        let _ = loader.revision
        let wanted = wantedKeys(plan)
        Canvas { context, _ in
            for tile in plan.tiles {
                draw(tile, plan: plan, in: &context)
            }
        }
        .onChange(of: wanted, initial: true) { _, keys in
            loader.load(keys)
        }
        .overlay {
            if plan.tileZoom < layer.minZoom {
                Text("Zoom in to see \(layer.name)")
                    .font(.callout)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .allowsHitTesting(false)
    }

    /// NAIP tiles are placed by NAD83 coordinates. This moves them onto WGS84; see `NAD83`.
    private var datumShift: CGSize {
        guard layer == .naip else { return .zero }
        let center = camera.center
        let offset = NAD83.offset(near: center)
        let projection = camera.projection
        let wgs84 = projection.point(for: center)
        let nad83 = projection.point(for: Coordinate(lat: center.lat + offset.latitude, lon: center.lon + offset.longitude))
        return CGSize(width: wgs84.x - nad83.x, height: wgs84.y - nad83.y)
    }

    /// Visible tiles that are not loaded, then the stand-ins for those the server lacks.
    private func wantedKeys(_ plan: TilePlan) -> [MapTileKey] {
        var keys = plan.tiles.map(\.key)
        var standIns: Set<MapTileKey> = []
        for tile in plan.tiles where loader.isMissing(tile.key) {
            var ancestor = tile.key.parent
            var level = 0
            while let key = ancestor, level < Self.fallbackLevels {
                if loader.image(for: key) != nil { break }
                if !loader.isMissing(key) {
                    standIns.insert(key)
                    break
                }
                ancestor = key.parent
                level += 1
            }
        }
        keys.append(contentsOf: standIns.sorted { $0.zoom > $1.zoom })
        return keys
    }

    private func draw(_ tile: TilePlan.Tile, plan: TilePlan, in context: inout GraphicsContext) {
        // Slightly oversized so no seams show between tiles at fractional zooms.
        let drawRect = tile.rect.insetBy(dx: -0.25, dy: -0.25)
        if let image = loader.image(for: tile.key) {
            context.draw(Self.image(image), in: drawRect)
            return
        }
        // Scale up the nearest loaded ancestor, clipped to this tile.
        var ancestor = tile.key.parent
        var levels = 1
        while let key = ancestor, levels <= Self.fallbackLevels {
            if let image = loader.image(for: key) {
                let size = tile.rect.width * CGFloat(1 << levels)
                let originX = tile.rect.minX - CGFloat(tile.key.x - (key.x << levels)) * tile.rect.width
                let originY = tile.rect.minY - CGFloat(tile.key.y - (key.y << levels)) * tile.rect.height
                context.drawLayer { layerContext in
                    layerContext.clip(to: Path(drawRect))
                    layerContext.draw(Self.image(image), in: CGRect(x: originX, y: originY, width: size, height: size))
                }
                return
            }
            ancestor = key.parent
            levels += 1
        }
    }

    private static func image(_ image: CGImage) -> Image {
        Image(decorative: image, scale: 1).interpolation(.medium)
    }
}

/// The tiles covering the map view at one camera position.
struct TilePlan {
    struct Tile {
        let key: MapTileKey
        /// Where the tile is drawn, in map view points.
        let rect: CGRect
    }

    let tileZoom: Int
    let tiles: [Tile]

    /// `displayScale` picks sharper tiles on Retina screens. `shift` moves every tile.
    init(projection: MapProjection, layer: ImageryLayer, displayScale: CGFloat, shift: CGSize) {
        tileZoom = min(Int((projection.zoom + log2(max(displayScale, 1))).rounded()), layer.maxZoom)
        guard tileZoom >= layer.minZoom, projection.size.width > 0, projection.size.height > 0 else {
            tiles = []
            return
        }
        // Points per tile at the camera's zoom.
        let tilePoints = CGFloat(WebMercator.tileSize) * pow(2, projection.zoom - Double(tileZoom))
        let count = 1 << tileZoom
        let left = projection.origin.x - shift.width
        let top = projection.origin.y - shift.height
        let minX = Int((left / tilePoints).rounded(.down))
        let maxX = Int(((left + projection.size.width) / tilePoints).rounded(.down))
        let minY = max(Int((top / tilePoints).rounded(.down)), 0)
        let maxY = min(Int(((top + projection.size.height) / tilePoints).rounded(.down)), count - 1)
        guard minY <= maxY else {
            tiles = []
            return
        }

        var tiles: [Tile] = []
        for y in minY...maxY {
            for x in minX...maxX {
                let wrappedX = ((x % count) + count) % count
                let rect = CGRect(
                    x: CGFloat(x) * tilePoints - left,
                    y: CGFloat(y) * tilePoints - top,
                    width: tilePoints,
                    height: tilePoints
                )
                tiles.append(Tile(key: MapTileKey(layer: layer, zoom: tileZoom, x: wrappedX, y: y), rect: rect))
            }
        }
        // Load the middle of the view first.
        let center = CGPoint(x: projection.size.width / 2, y: projection.size.height / 2)
        self.tiles = tiles.sorted {
            hypot($0.rect.midX - center.x, $0.rect.midY - center.y) < hypot($1.rect.midX - center.x, $1.rect.midY - center.y)
        }
    }
}

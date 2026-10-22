import CoreGraphics
import Foundation
import Observation
import CourseDataSwift

/// Converts between coordinates and points in the map view for one camera position.
struct MapProjection {
    /// Fractional Web Mercator zoom.
    let zoom: Double
    /// World pixel at the map view's top-left corner.
    let origin: CGPoint
    let size: CGSize

    func point(for coordinate: Coordinate) -> CGPoint {
        let world = WebMercator.pixel(for: coordinate, zoom: zoom)
        return CGPoint(x: world.x - origin.x, y: world.y - origin.y)
    }

    func coordinate(at point: CGPoint) -> Coordinate {
        WebMercator.coordinate(forPixel: CGPoint(x: point.x + origin.x, y: point.y + origin.y), zoom: zoom)
    }

    /// Degrees of latitude covered by a vertical run of points at the center of the view.
    func latitudeDegrees(forPoints points: CGFloat) -> Double {
        let top = coordinate(at: CGPoint(x: size.width / 2, y: size.height / 2))
        let bottom = coordinate(at: CGPoint(x: size.width / 2, y: size.height / 2 + points))
        return abs(top.lat - bottom.lat)
    }
}

/// Where the map editor is looking.
///
/// Views that draw on the map read it; the editor itself only reads it in event handlers,
/// so panning and zooming do not redraw the whole editor.
@MainActor
@Observable
final class MapCamera {
    static let zoomRange: ClosedRange<Double> = 2...22

    var center = Coordinate(lat: 39.5, lon: -98.35)
    var zoom: Double = 4
    var size: CGSize = .zero

    /// The coordinate under the mouse, if it is over the map.
    @ObservationIgnored var hoveredCoordinate: Coordinate?
    /// The mouse location in the map view, if it is over the map.
    @ObservationIgnored var hoveredPoint: CGPoint?

    var projection: MapProjection {
        let world = WebMercator.pixel(for: center, zoom: zoom)
        return MapProjection(
            zoom: zoom,
            origin: CGPoint(x: world.x - size.width / 2, y: world.y - size.height / 2),
            size: size
        )
    }

    /// Moves the map with the mouse: content moves by `translation` points.
    func pan(by translation: CGSize) {
        let world = WebMercator.pixel(for: center, zoom: zoom)
        let moved = CGPoint(x: world.x - translation.width, y: world.y - translation.height)
        let worldSize = WebMercator.worldSize(zoom: zoom)
        center = WebMercator.coordinate(
            forPixel: CGPoint(x: moved.x, y: min(max(moved.y, 0), worldSize)),
            zoom: zoom
        )
    }

    /// Zooms in to the next whole zoom level, keeping the coordinate under `anchor` in place.
    func zoomIn(anchor: CGPoint? = nil) {
        setZoom(zoom.rounded(.down) + 1, anchor: anchor)
    }

    /// Zooms out to the previous whole zoom level.
    func zoomOut() {
        setZoom(zoom.rounded(.up) - 1)
    }

    /// Zooms while keeping the coordinate under `anchor` in place.
    func setZoom(_ newZoom: Double, anchor: CGPoint? = nil) {
        let clamped = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard clamped != zoom else { return }
        guard let anchor else {
            zoom = clamped
            return
        }
        let anchored = projection.coordinate(at: anchor)
        zoom = clamped
        let moved = projection.point(for: anchored)
        pan(by: CGSize(width: anchor.x - moved.x, height: anchor.y - moved.y))
    }
}

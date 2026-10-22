import CoreGraphics
import Testing
@testable import CourseBuilder
import CourseDataSwift

@MainActor
struct MapCameraTests {
    private let course = Coordinate(lat: 40.0046, lon: -105.0234)

    private func camera(zoom: Double = 17.5) -> MapCamera {
        let camera = MapCamera()
        camera.center = course
        camera.zoom = zoom
        camera.size = CGSize(width: 800, height: 600)
        return camera
    }

    @Test func centerIsInTheMiddleOfTheView() {
        let point = camera().projection.point(for: course)
        #expect(abs(point.x - 400) < 1e-6)
        #expect(abs(point.y - 300) < 1e-6)
    }

    @Test func pointAndCoordinateRoundTrip() {
        let projection = camera().projection
        let coordinate = projection.coordinate(at: CGPoint(x: 123.5, y: 456.25))
        let point = projection.point(for: coordinate)
        #expect(abs(point.x - 123.5) < 1e-6)
        #expect(abs(point.y - 456.25) < 1e-6)
    }

    @Test func panMovesContentWithTheMouse() {
        let camera = camera()
        camera.pan(by: CGSize(width: 50, height: -20))
        let point = camera.projection.point(for: course)
        #expect(abs(point.x - 450) < 1e-6)
        #expect(abs(point.y - 280) < 1e-6)
    }

    @Test func zoomKeepsAnchorInPlace() {
        let camera = camera()
        let anchor = CGPoint(x: 600, y: 150)
        let anchored = camera.projection.coordinate(at: anchor)
        camera.setZoom(19.25, anchor: anchor)
        let point = camera.projection.point(for: anchored)
        #expect(camera.zoom == 19.25)
        #expect(abs(point.x - anchor.x) < 1e-6)
        #expect(abs(point.y - anchor.y) < 1e-6)
    }

    @Test func zoomInAndOutStepToWholeLevels() {
        let camera = camera(zoom: 17.5)
        camera.zoomIn()
        #expect(camera.zoom == 18)
        camera.zoomIn()
        #expect(camera.zoom == 19)
        camera.zoomOut()
        #expect(camera.zoom == 18)
        camera.setZoom(16.25)
        camera.zoomOut()
        #expect(camera.zoom == 16)
    }

    @Test func zoomInKeepsAnchorInPlace() {
        let camera = camera(zoom: 17.5)
        let anchor = CGPoint(x: 200, y: 450)
        let anchored = camera.projection.coordinate(at: anchor)
        camera.zoomIn(anchor: anchor)
        let point = camera.projection.point(for: anchored)
        #expect(camera.zoom == 18)
        #expect(abs(point.x - anchor.x) < 1e-6)
        #expect(abs(point.y - anchor.y) < 1e-6)
    }

    @Test func zoomIsClamped() {
        let camera = camera()
        camera.setZoom(40)
        #expect(camera.zoom == MapCamera.zoomRange.upperBound)
    }

    @Test func tilePlanUsesSharperTilesOnRetina() {
        let projection = camera(zoom: 17.5).projection
        let plan = TilePlan(projection: projection, layer: .esri, displayScale: 2, shift: .zero)
        #expect(plan.tileZoom == 19)
        // Zoom 19 tiles shown at zoom 17.5 are about 90.5 points wide, so the 800 by 600 view
        // needs at least 9 by 7 of them.
        #expect(plan.tiles.count >= 63)
        #expect(abs(plan.tiles[0].rect.width - 90.51) < 0.01)
        #expect(plan.tiles.allSatisfy { $0.key.zoom == 19 })
    }

    @Test func tilePlanStopsAtLayerZoomLimits() {
        #expect(TilePlan(projection: camera(zoom: 21).projection, layer: .naip, displayScale: 2, shift: .zero).tileZoom == 19)
        #expect(TilePlan(projection: camera(zoom: 10).projection, layer: .naip, displayScale: 1, shift: .zero).tiles.isEmpty)
    }

    @Test func tilePlanCoversTheCenter() {
        let projection = camera().projection
        let plan = TilePlan(projection: projection, layer: .esri, displayScale: 1, shift: .zero)
        let middle = CGPoint(x: 400, y: 300)
        #expect(plan.tiles.first?.rect.contains(middle) == true)
    }
}

import CoreGraphics
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct ImagePatchTests {
    @Test func pixelAndCoordinateRoundTrip() {
        let patch = ImagePatch(zoom: 19, originX: 27_000_000, originY: 50_000_000, width: 512, height: 512)
        let coordinate = patch.coordinate(forPixel: CGPoint(x: 100.25, y: 400.75))
        let pixel = patch.pixel(for: coordinate)
        #expect(abs(pixel.x - 100.25) < 1e-6)
        #expect(abs(pixel.y - 400.75) < 1e-6)
    }

    @Test func webMercatorMatchesKnownTile() {
        // Colorado National Golf Club falls in tile 19/109192/198475.
        let pixel = WebMercator.pixel(for: Coordinate(lat: 40.0046, lon: -105.0234), zoom: 19)
        #expect(Int(pixel.x) / 256 == 109_192)
        #expect(Int(pixel.y) / 256 == 198_475)
    }

    @Test func metersPerPixelAtFortyDegrees() {
        let mpp = WebMercator.metersPerPixel(latitude: 40, zoom: 19)
        #expect(abs(mpp - 0.2287) < 0.001)
    }

    @Test func containsBox() {
        let patch = SyntheticImagery.patch(size: 256) { _, _ in SyntheticImagery.grass }
        let inside = OverpassAPIClient.BoundingBox(around: SyntheticImagery.center, radiusMeters: 10)
        let outside = OverpassAPIClient.BoundingBox(around: SyntheticImagery.center, radiusMeters: 100)
        #expect(patch.contains(inside))
        #expect(!patch.contains(outside))
    }
}

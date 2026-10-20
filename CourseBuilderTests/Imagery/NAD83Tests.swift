import CoreGraphics
import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct NAD83Tests {
    private let coloradoNational = Coordinate(latitude: 40.0046, longitude: -105.0234)

    @Test func offsetAtColoradoNational() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 18)))
        let offset = NAD83.offset(near: coloradoNational, at: date)
        let east = offset.longitude * 111_320 * cos(coloradoNational.latitude * .pi / 180)
        let north = offset.latitude * 111_320
        // Matches the shift measured between NAIP fits and features placed on Apple imagery.
        #expect(abs(east - 1.35) < 0.05, "east \(east) m")
        #expect(abs(north + 0.52) < 0.05, "north \(north) m")
    }

    @Test func patchShiftsPixelsByOffset() {
        var patch = ImagePatch(zoom: 19, originX: 27_955_000, originY: 50_809_000, width: 512, height: 512)
        let before = patch.pixel(for: coloradoNational)
        patch.datumOffset = NAD83.offset(near: coloradoNational)
        let after = patch.pixel(for: coloradoNational)
        let mpp = WebMercator.metersPerPixel(latitude: coloradoNational.latitude, zoom: 19)
        // About 1.3 m east and 0.5 m south: NAIP shows the same ground east and south.
        #expect(abs(Double(after.x - before.x) * mpp - 1.35) < 0.1)
        #expect(abs(Double(after.y - before.y) * mpp - 0.52) < 0.1)
    }

    @Test func patchRoundTripWithOffset() {
        var patch = ImagePatch(zoom: 19, originX: 27_955_000, originY: 50_809_000, width: 512, height: 512)
        patch.datumOffset = NAD83.offset(near: coloradoNational)
        let back = patch.coordinate(forPixel: patch.pixel(for: coloradoNational))
        #expect(abs(back.latitude - coloradoNational.latitude) < 1e-10)
        #expect(abs(back.longitude - coloradoNational.longitude) < 1e-10)
    }

    @Test func decimalYear() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 12)))
        #expect(abs(NAD83.decimalYear(date) - 2026.5) < 0.01)
    }
}

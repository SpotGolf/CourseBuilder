import CoreGraphics
import Foundation
@testable import CourseBuilder
import CourseDataSwift

/// Builds fake NAIP patches for detection tests.
enum SyntheticImagery {
    struct Color {
        let r: UInt8, g: UInt8, b: UInt8, nir: UInt8
    }

    static let zoom = 19
    static let center = Coordinate(latitude: 40.0, longitude: -105.0)

    static let grass = Color(r: 60, g: 110, b: 50, nir: 180)
    static let sand = Color(r: 210, g: 195, b: 160, nir: 210)
    static let grey = Color(r: 150, g: 150, b: 150, nir: 150)
    static let water = Color(r: 30, g: 45, b: 55, nir: 15)
    static let fairway = Color(r: 90, g: 140, b: 60, nir: 200)
    static let rough = Color(r: 50, g: 85, b: 40, nir: 150)
    /// Median NAIP colors measured inside fairways and rough at Colorado National. They are
    /// close enough that growing from fairway colors takes in the rough too.
    static let realFairway = Color(r: 77, g: 106, b: 57, nir: 203)
    static let realRough = Color(r: 68, g: 93, b: 54, nir: 199)

    static var metersPerPixel: Double {
        WebMercator.metersPerPixel(latitude: center.latitude, zoom: zoom)
    }

    /// A size×size patch centered on `center`. `paint` gets each pixel center's offset in
    /// meters east and north of `center`.
    static func patch(size: Int = 512, paint: (_ east: Double, _ north: Double) -> Color) -> ImagePatch {
        let centerPixel = WebMercator.pixel(for: center, zoom: zoom)
        let originX = Int(centerPixel.x) - size / 2
        let originY = Int(centerPixel.y) - size / 2
        var patch = ImagePatch(zoom: zoom, originX: originX, originY: originY, width: size, height: size)
        let mpp = metersPerPixel
        for y in 0..<size {
            for x in 0..<size {
                let global = CGPoint(x: Double(originX + x) + 0.5, y: Double(originY + y) + 0.5)
                let east = (Double(global.x) - Double(centerPixel.x)) * mpp
                let north = (Double(centerPixel.y) - Double(global.y)) * mpp
                let color = paint(east, north)
                let i = patch.index(x, y)
                patch.red[i] = color.r
                patch.green[i] = color.g
                patch.blue[i] = color.b
                patch.nir[i] = color.nir
                patch.valid[i] = true
            }
        }
        return patch
    }

    static func coordinate(east: Double, north: Double) -> Coordinate {
        Coordinate(
            latitude: center.latitude + north / 111_320.0,
            longitude: center.longitude + east / (111_320.0 * cos(center.latitude * .pi / 180))
        )
    }

    /// Circle polygon of `count` points.
    static func circle(east: Double, north: Double, radius: Double, count: Int = 32) -> [Coordinate] {
        (0..<count).map { i in
            let angle = Double(i) / Double(count) * 2 * .pi
            return coordinate(east: east + radius * cos(angle), north: north + radius * sin(angle))
        }
    }

    /// Polygon area in square meters.
    static func area(_ polygon: [Coordinate]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        let lat0 = polygon[0].latitude
        let points = polygon.map { c in
            (x: (c.longitude - polygon[0].longitude) * 111_320.0 * cos(lat0 * .pi / 180),
             y: (c.latitude - lat0) * 111_320.0)
        }
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Centroid offset in meters east and north of `center`.
    static func centroidOffset(_ polygon: [Coordinate]) -> (east: Double, north: Double) {
        let c = PolygonGeometry.centroid(of: polygon)
        return ((c.longitude - center.longitude) * 111_320.0 * cos(center.latitude * .pi / 180),
                (c.latitude - center.latitude) * 111_320.0)
    }
}

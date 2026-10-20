import CoreGraphics
import Foundation
import ImageIO
import CourseDataSwift

/// Web Mercator math for 256-pixel map tiles. Pixel positions are global: (0, 0) is the
/// top-left corner of the world at the given zoom.
enum WebMercator {
    static let tileSize = 256

    static func worldSize(zoom: Int) -> Double {
        Double(tileSize) * pow(2, Double(zoom))
    }

    static func pixel(for coordinate: Coordinate, zoom: Int) -> CGPoint {
        let size = worldSize(zoom: zoom)
        let x = (coordinate.longitude + 180) / 360 * size
        let sinLat = sin(coordinate.latitude * .pi / 180)
        let y = (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)) * size
        return CGPoint(x: x, y: y)
    }

    static func coordinate(forPixel pixel: CGPoint, zoom: Int) -> Coordinate {
        let size = worldSize(zoom: zoom)
        let longitude = Double(pixel.x) / size * 360 - 180
        let n = .pi - 2 * .pi * Double(pixel.y) / size
        let latitude = atan(sinh(n)) * 180 / .pi
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    static func metersPerPixel(latitude: Double, zoom: Int) -> Double {
        156_543.033_92 * cos(latitude * .pi / 180) / pow(2, Double(zoom))
    }
}

/// A block of imagery pixels stitched from map tiles, with conversion between pixels and
/// coordinates. Channels are stored as bytes; `valid` is false where the source had no data.
/// Coordinates are WGS84; `datumOffset` corrects for imagery located in another datum.
struct ImagePatch {
    let zoom: Int
    /// Global pixel position of the patch's top-left corner.
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    var red: [UInt8]
    var green: [UInt8]
    var blue: [UInt8]
    var nir: [UInt8]
    var valid: [Bool]
    /// Added to a WGS84 coordinate to get the coordinate the imagery's pixels are placed by.
    /// NAIP tiles are placed by NAD83 coordinates; see `NAD83`.
    var datumOffset: NAD83.Offset = .zero

    init(zoom: Int, originX: Int, originY: Int, width: Int, height: Int) {
        self.zoom = zoom
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        let count = width * height
        red = Array(repeating: 0, count: count)
        green = Array(repeating: 0, count: count)
        blue = Array(repeating: 0, count: count)
        nir = Array(repeating: 0, count: count)
        valid = Array(repeating: false, count: count)
    }

    func index(_ x: Int, _ y: Int) -> Int { y * width + x }

    /// Position of a coordinate in patch pixels. Pixel (x, y) covers x..<x+1, y..<y+1.
    func pixel(for coordinate: Coordinate) -> CGPoint {
        let shifted = Coordinate(latitude: coordinate.latitude + datumOffset.latitude,
                                 longitude: coordinate.longitude + datumOffset.longitude)
        let global = WebMercator.pixel(for: shifted, zoom: zoom)
        return CGPoint(x: global.x - CGFloat(originX), y: global.y - CGFloat(originY))
    }

    func coordinate(forPixel pixel: CGPoint) -> Coordinate {
        let placed = WebMercator.coordinate(
            forPixel: CGPoint(x: pixel.x + CGFloat(originX), y: pixel.y + CGFloat(originY)),
            zoom: zoom
        )
        return Coordinate(latitude: placed.latitude - datumOffset.latitude,
                          longitude: placed.longitude - datumOffset.longitude)
    }

    var metersPerPixel: Double {
        let center = coordinate(forPixel: CGPoint(x: Double(width) / 2, y: Double(height) / 2))
        return WebMercator.metersPerPixel(latitude: center.latitude, zoom: zoom)
    }

    func contains(_ box: OverpassAPIClient.BoundingBox) -> Bool {
        let topLeft = pixel(for: Coordinate(latitude: box.north, longitude: box.west))
        let bottomRight = pixel(for: Coordinate(latitude: box.south, longitude: box.east))
        return topLeft.x >= 0 && topLeft.y >= 0
            && bottomRight.x <= CGFloat(width) && bottomRight.y <= CGFloat(height)
    }

    /// Copies a tile's pixels into place. For the color tile the red, green, and blue channels
    /// are used. For the false-color tile (bands 4, 1, 2) the first channel is near-infrared.
    mutating func place(rgbTile: CGImage?, falseColorTile: CGImage?, tileX: Int, tileY: Int) {
        let size = WebMercator.tileSize
        let offsetX = tileX * size - originX
        let offsetY = tileY * size - originY
        let rgb = rgbTile.flatMap(Self.rgbaBytes)
        let falseColor = falseColorTile.flatMap(Self.rgbaBytes)
        guard rgb != nil || falseColor != nil else { return }

        for ty in 0..<size {
            let y = offsetY + ty
            guard y >= 0, y < height else { continue }
            for tx in 0..<size {
                let x = offsetX + tx
                guard x >= 0, x < width else { continue }
                let source = (ty * size + tx) * 4
                let target = index(x, y)
                var isValid = true
                if let rgb {
                    red[target] = rgb[source]
                    green[target] = rgb[source + 1]
                    blue[target] = rgb[source + 2]
                    isValid = isValid && rgb[source + 3] > 0
                } else {
                    isValid = false
                }
                if let falseColor {
                    nir[target] = falseColor[source]
                    isValid = isValid && falseColor[source + 3] > 0
                } else {
                    isValid = false
                }
                valid[target] = isValid
            }
        }
    }

    /// Draws an image into a 256×256 RGBA buffer. Alpha is premultiplied, but NAIP pixels are
    /// either fully opaque or empty, so the color values of data pixels are exact.
    static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let size = WebMercator.tileSize
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return drawn ? bytes : nil
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

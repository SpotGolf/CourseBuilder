import Foundation
import CourseDataSwift

/// Converts between WGS84 (GPS and Apple Maps) and NAD83(2011), the datum NAIP imagery is
/// located in. The imagery tile server treats NAD83 as WGS84, which places NAIP about 1–2 m off
/// in the United States (about 1.3 m east and 0.5 m south at Colorado National Golf Club).
///
/// Uses the NGS 14-parameter transformation from ITRF2008 to NAD83(2011) (Pearson & Snay, 2013).
/// WGS84 matches ITRF2008 to within a few centimeters.
enum NAD83 {
    /// The offset to add to a WGS84 coordinate to get its NAD83 coordinate, in degrees.
    struct Offset: Equatable {
        static let zero = Offset(latitude: 0, longitude: 0)

        let latitude: Double
        let longitude: Double
    }

    /// The offset near `coordinate`. It changes by millimeters across a golf course, so one
    /// value serves a whole imagery patch.
    static func offset(near coordinate: Coordinate, at date: Date = Date()) -> Offset {
        let nad83 = fromWGS84(coordinate, epoch: decimalYear(date))
        return Offset(latitude: nad83.latitude - coordinate.latitude, longitude: nad83.longitude - coordinate.longitude)
    }

    // MARK: - Transformation

    private static let referenceEpoch = 1997.0
    private static let translation = (x: 0.99343, y: -1.90331, z: -0.52655)          // m
    private static let translationRate = (x: 0.00079, y: -0.00060, z: -0.00134)     // m/yr
    private static let rotation = (x: 25.91467, y: 9.42645, z: 11.59935)            // mas
    private static let rotationRate = (x: 0.06667, y: -0.75744, z: -0.05133)        // mas/yr
    private static let scale = 1.71504                                              // ppb
    private static let scaleRate = -0.10201                                         // ppb/yr

    /// GRS80 ellipsoid, shared by both datums to well under a millimeter.
    private static let semiMajorAxis = 6_378_137.0
    private static let flattening = 1 / 298.257_222_101

    static func fromWGS84(_ coordinate: Coordinate, epoch: Double) -> Coordinate {
        let dt = epoch - referenceEpoch
        let milliarcsecond = Double.pi / 180 / 3_600_000
        let tx = translation.x + translationRate.x * dt
        let ty = translation.y + translationRate.y * dt
        let tz = translation.z + translationRate.z * dt
        let rx = (rotation.x + rotationRate.x * dt) * milliarcsecond
        let ry = (rotation.y + rotationRate.y * dt) * milliarcsecond
        let rz = (rotation.z + rotationRate.z * dt) * milliarcsecond
        let s = 1 + (scale + scaleRate * dt) * 1e-9

        let (x, y, z) = cartesian(coordinate)
        let nx = tx + s * x + rz * y - ry * z
        let ny = ty - rz * x + s * y + rx * z
        let nz = tz + ry * x - rx * y + s * z
        return geodetic(x: nx, y: ny, z: nz)
    }

    private static var eccentricitySquared: Double { flattening * (2 - flattening) }

    private static func cartesian(_ c: Coordinate) -> (Double, Double, Double) {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        let h = c.elevation ?? 0
        let n = semiMajorAxis / (1 - eccentricitySquared * sin(lat) * sin(lat)).squareRoot()
        return ((n + h) * cos(lat) * cos(lon),
                (n + h) * cos(lat) * sin(lon),
                (n * (1 - eccentricitySquared) + h) * sin(lat))
    }

    private static func geodetic(x: Double, y: Double, z: Double) -> Coordinate {
        let lon = atan2(y, x)
        let p = (x * x + y * y).squareRoot()
        var lat = atan2(z, p * (1 - eccentricitySquared))
        for _ in 0..<5 {
            let n = semiMajorAxis / (1 - eccentricitySquared * sin(lat) * sin(lat)).squareRoot()
            let h = p / cos(lat) - n
            lat = atan2(z, p * (1 - eccentricitySquared * n / (n + h)))
        }
        return Coordinate(latitude: lat * 180 / .pi, longitude: lon * 180 / .pi)
    }

    static func decimalYear(_ date: Date) -> Double {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        guard let start = calendar.date(from: DateComponents(year: year)),
              let end = calendar.date(from: DateComponents(year: year + 1)) else { return Double(year) }
        return Double(year) + date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}

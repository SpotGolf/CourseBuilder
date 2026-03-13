import Foundation
import CoreLocation

enum PolygonGeometry {
    /// Centroid of a polygon using the signed-area formula.
    static func centroid(of polygon: [Coordinate]) -> Coordinate {
        guard !polygon.isEmpty else {
            return Coordinate(latitude: 0, longitude: 0)
        }
        guard polygon.count > 1 else {
            return polygon[0]
        }

        var cx = 0.0, cy = 0.0, area = 0.0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            let cross = polygon[i].latitude * polygon[j].longitude - polygon[j].latitude * polygon[i].longitude
            area += cross
            cx += (polygon[i].latitude + polygon[j].latitude) * cross
            cy += (polygon[i].longitude + polygon[j].longitude) * cross
        }
        area /= 2.0
        guard abs(area) > 1e-10 else {
            let lat = polygon.map(\.latitude).reduce(0, +) / Double(n)
            let lon = polygon.map(\.longitude).reduce(0, +) / Double(n)
            return Coordinate(latitude: lat, longitude: lon)
        }
        cx /= (6.0 * area)
        cy /= (6.0 * area)
        return Coordinate(latitude: cx, longitude: cy)
    }

    /// Unsigned area of a polygon (in coordinate-space units squared).
    static func area(of polygon: [Coordinate]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var area = 0.0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            area += polygon[i].latitude * polygon[j].longitude
            area -= polygon[j].latitude * polygon[i].longitude
        }
        return abs(area / 2.0)
    }

    /// Nearest vertex on polygon to a reference point.
    static func nearestPoint(on polygon: [Coordinate], to reference: Coordinate) -> Coordinate {
        guard !polygon.isEmpty else {
            return Coordinate(latitude: 0, longitude: 0)
        }
        let refLocation = reference.clLocation
        return polygon.min(by: {
            $0.clLocation.distance(from: refLocation) < $1.clLocation.distance(from: refLocation)
        })!
    }

    /// Farthest vertex on polygon from a reference point.
    static func farthestPoint(on polygon: [Coordinate], to reference: Coordinate) -> Coordinate {
        guard !polygon.isEmpty else {
            return Coordinate(latitude: 0, longitude: 0)
        }
        let refLocation = reference.clLocation
        return polygon.max(by: {
            $0.clLocation.distance(from: refLocation) < $1.clLocation.distance(from: refLocation)
        })!
    }

    /// Check if a coordinate is inside a polygon using ray casting.
    static func contains(_ point: Coordinate, in polygon: [Coordinate]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        let n = polygon.count
        var j = n - 1
        for i in 0..<n {
            let yi = polygon[i].latitude, xi = polygon[i].longitude
            let yj = polygon[j].latitude, xj = polygon[j].longitude
            if ((yi > point.latitude) != (yj > point.latitude)) &&
                (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

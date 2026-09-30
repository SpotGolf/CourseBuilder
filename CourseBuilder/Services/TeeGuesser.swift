import Foundation
import CourseDataSwift

/// Guesses which tee box each tee name plays from by walking the hole's centerline.
///
/// Every tee box is projected onto the centerline. Its back (the vertex farthest from the
/// green along the centerline) and its front (the vertex closest to the green) give a range
/// of distances to the green. Each tee name is assigned to the tee box whose range contains
/// the scorecard yardage, or to the tee box whose range is closest to it.
enum TeeGuesser {
    private static let metersPerYard = 0.9144
    private static let metersPerDegreeLatitude = 110_540.0
    private static let metersPerDegreeLongitudeAtEquator = 111_320.0

    /// The distance range from a tee box to the green, measured along the centerline.
    struct TeeRange: Equatable {
        let featureID: Int
        /// Yards from the front of the tee box to the green.
        let frontYards: Double
        /// Yards from the back of the tee box to the green.
        let backYards: Double
    }

    /// Returns tee name -> tee box feature ID for the hole. Returns an empty map when the hole
    /// has no yardages, no tee boxes, or a centerline with fewer than 2 points.
    static func guessTees(for hole: Hole, features: [Feature]) -> [String: Int] {
        let ranges = teeRanges(for: hole, features: features)
        guard !ranges.isEmpty else { return [:] }

        var tees: [String: Int] = [:]
        for (name, yards) in hole.yardages {
            if let best = bestRange(for: Double(yards), in: ranges) {
                tees[name] = best.featureID
            }
        }
        return tees
    }

    /// Computes the front and back distance to the green for each tee box of the hole.
    static func teeRanges(for hole: Hole, features: [Feature]) -> [TeeRange] {
        let centerline = hole.centerline
        guard centerline.count >= 2 else { return [] }

        let holeFeatures = features.filter { hole.features.contains($0.id) }
        let teeFeatures = holeFeatures.filter { $0.type == .tee && !$0.polygon.isEmpty }
        guard !teeFeatures.isEmpty else { return [] }

        let path = CenterlinePath(centerline)

        // Scorecard yardage is measured to the middle of the green. Fall back to the centerline end.
        let greenPosition: Double
        if let green = hole.green(from: holeFeatures), !green.polygon.isEmpty {
            greenPosition = path.position(of: green.center)
        } else {
            greenPosition = path.totalLength
        }

        return teeFeatures.map { tee in
            let positions = tee.polygon.map { path.position(of: $0) }
            let back = positions.min()!
            let front = positions.max()!
            return TeeRange(
                featureID: tee.id,
                frontYards: (greenPosition - front) / metersPerYard,
                backYards: (greenPosition - back) / metersPerYard
            )
        }
    }

    /// Picks the range that contains the yardage. When none does, picks the range with the
    /// nearest edge. Ties go to the range whose middle is closest to the yardage.
    private static func bestRange(for yards: Double, in ranges: [TeeRange]) -> TeeRange? {
        ranges.min { a, b in
            let gapA = gap(yards, a)
            let gapB = gap(yards, b)
            if gapA != gapB { return gapA < gapB }
            return abs(yards - middle(a)) < abs(yards - middle(b))
        }
    }

    private static func gap(_ yards: Double, _ range: TeeRange) -> Double {
        if yards < range.frontYards { return range.frontYards - yards }
        if yards > range.backYards { return yards - range.backYards }
        return 0
    }

    private static func middle(_ range: TeeRange) -> Double {
        (range.frontYards + range.backYards) / 2
    }

    /// A centerline converted to flat local meters so points can be projected onto it.
    private struct CenterlinePath {
        let origin: Coordinate
        let metersPerDegreeLongitude: Double
        let points: [(x: Double, y: Double)]
        /// Distance in meters from the centerline start to each point.
        let cumulative: [Double]

        var totalLength: Double { cumulative.last ?? 0 }

        init(_ centerline: [Coordinate]) {
            origin = centerline[0]
            metersPerDegreeLongitude = metersPerDegreeLongitudeAtEquator * cos(origin.latitude * .pi / 180)
            var points: [(x: Double, y: Double)] = []
            var cumulative: [Double] = []
            for coordinate in centerline {
                let point = (
                    x: (coordinate.longitude - origin.longitude) * metersPerDegreeLongitude,
                    y: (coordinate.latitude - origin.latitude) * metersPerDegreeLatitude
                )
                if let last = points.last {
                    cumulative.append(cumulative.last! + hypot(point.x - last.x, point.y - last.y))
                } else {
                    cumulative.append(0)
                }
                points.append(point)
            }
            self.points = points
            self.cumulative = cumulative
        }

        /// Distance in meters along the centerline to the point's projection. Points behind the
        /// start are negative and points past the end are greater than the total length.
        func position(of coordinate: Coordinate) -> Double {
            let px = (coordinate.longitude - origin.longitude) * metersPerDegreeLongitude
            let py = (coordinate.latitude - origin.latitude) * metersPerDegreeLatitude

            var bestDistSq = Double.greatestFiniteMagnitude
            var bestPosition = 0.0
            let lastSegment = points.count - 2
            for i in 0...lastSegment {
                let a = points[i]
                let b = points[i + 1]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let length = cumulative[i + 1] - cumulative[i]
                guard length > 1e-6 else { continue }

                let rawT = ((px - a.x) * dx + (py - a.y) * dy) / (length * length)
                let t = max(0, min(1, rawT))
                let nx = a.x + t * dx
                let ny = a.y + t * dy
                let distSq = (px - nx) * (px - nx) + (py - ny) * (py - ny)
                if distSq < bestDistSq {
                    bestDistSq = distSq
                    // Extend the first and last segments so tee boxes behind the start still get a position.
                    var along = t
                    if i == 0 && rawT < 0 { along = rawT }
                    if i == lastSegment && rawT > 1 { along = rawT }
                    bestPosition = cumulative[i] + along * length
                }
            }
            return bestPosition
        }
    }
}

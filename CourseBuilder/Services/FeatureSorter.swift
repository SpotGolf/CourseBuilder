import Foundation
import CourseDataSwift

/// Orders a hole's features in playing order: farthest from the green first, the green last.
enum FeatureSorter {
    /// Sorts `features` by straight-line distance from the hole's green, farthest first.
    /// The green itself is at distance zero and sorts last. Ties keep ascending ID order.
    ///
    /// The reference point is the center of the hole's green. When the hole has no green,
    /// the end of its centerline is used. With neither, the features are returned unchanged.
    static func sortedByDistanceFromGreen(_ features: [Feature], hole: Hole) -> [Feature] {
        guard let target = greenReference(for: hole, features: features) else { return features }
        let targetLocation = target.clLocation

        let withDistance = features.map { feature in
            (feature: feature, distance: feature.center.clLocation.distance(from: targetLocation))
        }
        return withDistance
            .sorted { a, b in
                if a.distance != b.distance { return a.distance > b.distance }
                return a.feature.id < b.feature.id
            }
            .map(\.feature)
    }

    private static func greenReference(for hole: Hole, features: [Feature]) -> Coordinate? {
        if let green = hole.green(from: features), !green.polygon.isEmpty {
            return green.center
        }
        return hole.centerline.last
    }
}

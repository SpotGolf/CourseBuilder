import Foundation
import CourseDataSwift

enum ElevationUpdater {
    /// How many points are asked for in one request.
    static let batchSize = USGSElevationClient.batchSize

    /// Looks up one elevation for each point, in order, with `nil` where there is no data.
    typealias Fetch = @Sendable ([Coordinate]) async throws -> [Double?]

    static let usgsFetch: Fetch = { coordinates in
        try await USGSElevationClient().elevations(for: coordinates)
    }

    /// Looks up the elevation of every point in the course that has none: the course location
    /// and feature points, including centerlines.
    ///
    /// A point USGS has no data for, for example because the course is outside the United
    /// States, is left with no elevation and added to `status`, so it is not asked for again.
    ///
    /// Throws if the service cannot be reached or answers with an error. What was looked up
    /// before the error stays in `course` and `status`, so calling again only asks for the rest.
    ///
    /// - Parameter progress: Called after each request with the points done and the points in all.
    /// - Returns: How many points got an elevation.
    @MainActor
    @discardableResult
    static func fetchMissingElevations(
        in course: inout Course,
        status: inout ElevationStatus,
        fetch: Fetch = usgsFetch,
        progress: (@MainActor (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Int {
        let missing = missingCoordinates(in: course, status: status)
        guard !missing.isEmpty else { return 0 }
        progress?(0, missing.count)

        var found = 0
        for start in stride(from: 0, to: missing.count, by: batchSize) {
            let batch = Array(missing[start..<min(start + batchSize, missing.count)])
            let lookup: Lookup
            do {
                lookup = resolve(batch, with: try await fetch(batch))
            } catch let error as USGSElevationClient.ElevationError where error.isOutsideUnitedStates {
                lookup = resolve(batch, with: [])
            }
            try Task.checkCancellation()
            apply(lookup.elevations, to: &course)
            status.pointsWithoutData.formUnion(lookup.withoutData)
            found += lookup.elevations.count
            progress?(min(start + batchSize, missing.count), missing.count)
        }
        return found
    }

    /// A point's position, without its elevation. Elevations are matched to points by position.
    struct Location: Hashable, Codable {
        let latitude: Double
        let longitude: Double

        init(_ coordinate: Coordinate) {
            latitude = coordinate.lat
            longitude = coordinate.lon
        }
    }

    /// Returns each distinct point in the course that has no elevation, in file order. Points
    /// that `status` says USGS has no data for are left out.
    static func missingCoordinates(in course: Course, status: ElevationStatus = ElevationStatus()) -> [Coordinate] {
        var seen: Set<Location> = []
        var missing: [Coordinate] = []
        forEachCoordinate(in: course) { coordinate in
            let location = Location(coordinate)
            if coordinate.ele == nil, !status.pointsWithoutData.contains(location), seen.insert(location).inserted {
                missing.append(coordinate)
            }
        }
        return missing
    }

    /// The result of looking up elevations for a list of points.
    struct Lookup {
        /// The elevation for each point USGS has data for, by position.
        var elevations: [Location: Double]
        /// The points USGS has no data for.
        var withoutData: Set<Location>
    }

    /// Pairs each point with its looked-up elevation, in order.
    static func resolve(_ coordinates: [Coordinate], with results: [Double?]) -> Lookup {
        var lookup = Lookup(elevations: [:], withoutData: [])
        for (index, coordinate) in coordinates.enumerated() {
            if index < results.count, let elevation = results[index] {
                lookup.elevations[Location(coordinate)] = elevation
            } else {
                lookup.withoutData.insert(Location(coordinate))
            }
        }
        return lookup
    }

    /// Sets the elevation of every point that has none and whose position is in `elevations`.
    /// Points that moved since the elevations were looked up are left alone.
    static func apply(_ elevations: [Location: Double], to course: inout Course) {
        guard !elevations.isEmpty else { return }
        forEachCoordinate(in: &course) { coordinate in
            if coordinate.ele == nil, let elevation = elevations[Location(coordinate)] {
                coordinate.ele = elevation
            }
        }
    }

    /// Reads every coordinate in the course file, in the same order as the mutating version.
    private static func forEachCoordinate(in course: Course, _ body: (Coordinate) -> Void) {
        body(course.location.coordinate)
        for feature in course.features {
            feature.polygon.forEach(body)
        }
    }

    /// Visits every coordinate in the course file, always in the same order.
    private static func forEachCoordinate(in course: inout Course, _ body: (inout Coordinate) -> Void) {
        body(&course.location.coordinate)
        for f in course.features.indices {
            course.features[f].polygon = updating(course.features[f].polygon, body)
        }
    }

    /// Returns a copy of the path with `body` applied to each point. A path's points can't be changed in place.
    private static func updating(_ path: CoordinatePath, _ body: (inout Coordinate) -> Void) -> CoordinatePath {
        CoordinatePath(path.map { coordinate in
            var coordinate = coordinate
            body(&coordinate)
            return coordinate
        })
    }
}

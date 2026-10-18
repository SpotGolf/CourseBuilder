import Foundation
import CourseDataSwift

extension Course {
    /// Whether any feature polygon point or hole centerline point has no elevation.
    var isMissingElevations: Bool {
        features.contains { $0.polygon.contains { $0.elevation == nil } }
            || subCourses.contains { $0.holes.contains { $0.centerline.contains { $0.elevation == nil } } }
    }
}

enum ElevationUpdater {
    /// Returns a copy of the course with an elevation on every coordinate that lacked one:
    /// the course location, feature polygons, and hole centerlines.
    ///
    /// Throws ``USGSElevationClient/ElevationError/noData(missing:total:)`` if any point
    /// could not be resolved, so a course is never saved partially updated.
    static func update(
        _ course: Course,
        using client: USGSElevationClient = USGSElevationClient(),
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Course {
        var updated = course
        var missing: [Coordinate] = []
        forEachCoordinate(in: &updated) { coordinate in
            if coordinate.elevation == nil {
                missing.append(coordinate)
            }
        }
        guard !missing.isEmpty else { return course }

        let elevations = try await client.elevations(for: missing, progress: progress)
        let resolved = elevations.compactMap { $0 }
        guard elevations.count == missing.count, resolved.count == missing.count else {
            throw USGSElevationClient.ElevationError.noData(missing: missing.count - resolved.count, total: missing.count)
        }

        var next = resolved.makeIterator()
        forEachCoordinate(in: &updated) { coordinate in
            if coordinate.elevation == nil {
                coordinate.elevation = next.next()
            }
        }
        return updated
    }

    /// Returns a copy of the course with `elevation` on every coordinate that lacked one.
    static func fillingMissingElevations(of course: Course, with elevation: Double) -> Course {
        var updated = course
        forEachCoordinate(in: &updated) { coordinate in
            if coordinate.elevation == nil {
                coordinate.elevation = elevation
            }
        }
        return updated
    }

    /// A point's position, without its elevation. Elevations are matched to points by position.
    struct Location: Hashable {
        let latitude: Double
        let longitude: Double

        init(_ coordinate: Coordinate) {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        }
    }

    /// Returns each distinct point in the course that has no elevation, in file order.
    static func missingCoordinates(in course: Course) -> [Coordinate] {
        var seen: Set<Location> = []
        var missing: [Coordinate] = []
        forEachCoordinate(in: course) { coordinate in
            if coordinate.elevation == nil, seen.insert(Location(coordinate)).inserted {
                missing.append(coordinate)
            }
        }
        return missing
    }

    /// The result of looking up elevations for a list of points.
    struct Lookup {
        /// The elevation for each point, by position.
        var elevations: [Location: Double]
        /// How many points USGS had no data for. These are set to sea level.
        var seaLevelPoints: Int
    }

    /// Pairs each point with its looked-up elevation, in order. Points USGS has no data for are set to sea level.
    static func resolve(_ coordinates: [Coordinate], with results: [Double?]) -> Lookup {
        var lookup = Lookup(elevations: [:], seaLevelPoints: 0)
        for (index, coordinate) in coordinates.enumerated() {
            if index < results.count, let elevation = results[index] {
                lookup.elevations[Location(coordinate)] = elevation
            } else {
                lookup.elevations[Location(coordinate)] = 0
                lookup.seaLevelPoints += 1
            }
        }
        return lookup
    }

    /// Looks up the elevation of every point in the course that has none.
    ///
    /// If USGS has no data for a point, for example because the course is outside the United States,
    /// the point is set to sea level. Throws if the service cannot be reached or answers with an error.
    static func lookUpMissingElevations(
        in course: Course,
        fetch: ElevationWorker.Fetch = ElevationWorker.usgsFetch
    ) async throws -> Lookup {
        let missing = missingCoordinates(in: course)
        guard !missing.isEmpty else { return Lookup(elevations: [:], seaLevelPoints: 0) }
        do {
            return resolve(missing, with: try await fetch(missing))
        } catch let error as USGSElevationClient.ElevationError where error.isOutsideUnitedStates {
            return resolve(missing, with: [])
        }
    }

    /// Sets the elevation of every point that has none and whose position is in `elevations`.
    /// Points that moved since the elevations were looked up are left alone.
    static func apply(_ elevations: [Location: Double], to course: inout Course) {
        guard !elevations.isEmpty else { return }
        forEachCoordinate(in: &course) { coordinate in
            if coordinate.elevation == nil, let elevation = elevations[Location(coordinate)] {
                coordinate.elevation = elevation
            }
        }
    }

    /// Reads every coordinate in the course file, in the same order as the mutating version.
    private static func forEachCoordinate(in course: Course, _ body: (Coordinate) -> Void) {
        body(course.location.coordinate)
        for feature in course.features {
            feature.polygon.forEach(body)
        }
        for subCourse in course.subCourses {
            for hole in subCourse.holes {
                hole.centerline.forEach(body)
            }
        }
    }

    /// Visits every coordinate in the course file, always in the same order.
    private static func forEachCoordinate(in course: inout Course, _ body: (inout Coordinate) -> Void) {
        body(&course.location.coordinate)
        for f in course.features.indices {
            for p in course.features[f].polygon.indices {
                body(&course.features[f].polygon[p])
            }
        }
        for s in course.subCourses.indices {
            for h in course.subCourses[s].holes.indices {
                for c in course.subCourses[s].holes[h].centerline.indices {
                    body(&course.subCourses[s].holes[h].centerline[c])
                }
            }
        }
    }
}

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

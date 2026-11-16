import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "CourseElevationFetch")

/// Fetches everything a course needs from USGS before it can be used: the elevation of every
/// point, then the surface of every green.
///
/// Where USGS has no data, the point or green is left empty and recorded in the status. That is
/// not a failure. A failure is a fetch that does not work, such as a network error.
enum CourseElevationFetch {
    /// How many times in a row a fetch is tried before giving up.
    static let maxAttempts = 3

    /// What the fetch is doing, for the user.
    enum Progress: Equatable {
        case points(completed: Int, total: Int)
        case greens(completed: Int, total: Int)
        /// A fetch failed and is being tried again.
        case retrying(attempt: Int, maxAttempts: Int)

        var message: String {
            switch self {
            case .points(let completed, let total):
                "Elevations: \(completed.formatted()) of \(total.formatted()) points"
            case .greens(let completed, let total):
                "Green surfaces: \(completed.formatted()) of \(total.formatted()) greens"
            case .retrying(let attempt, let maxAttempts):
                "The fetch failed. Trying again (try \(attempt) of \(maxAttempts))..."
            }
        }

        /// How far along the current part is, from 0 to 1. Nil while waiting to retry.
        var fraction: Double? {
            switch self {
            case .points(let completed, let total), .greens(let completed, let total):
                total > 0 ? Double(completed) / Double(total) : nil
            case .retrying:
                nil
            }
        }
    }

    /// Fetches the missing point elevations and green surfaces of a course.
    ///
    /// A failed fetch is tried again, up to ``maxAttempts`` times in a row. Each try only asks
    /// for what is still missing. Throws the last error when every try failed, with what was
    /// fetched so far left in `course` and `status`, so calling again carries on from there.
    @MainActor
    static func run(
        course: inout Course,
        status: inout ElevationStatus,
        pointFetch: ElevationUpdater.Fetch = ElevationUpdater.usgsFetch,
        greenFetch: GreenSurfaceUpdater.Fetch = GreenSurfaceUpdater.usgsFetch,
        retryDelay: Duration = .seconds(5),
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws {
        var failures = 0
        while true {
            let remainingBefore = remaining(in: course, status: status)
            do {
                try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status, fetch: pointFetch) {
                    progress(.points(completed: $0, total: $1))
                }
                try await GreenSurfaceUpdater.fetchMissingSurfaces(in: &course, status: &status, fetch: greenFetch) {
                    progress(.greens(completed: $0, total: $1))
                }
                status.prune(to: course)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                // A try that got something done starts the count again.
                failures = remaining(in: course, status: status) < remainingBefore ? 1 : failures + 1
                logger.error("Elevation fetch failed (\(failures, privacy: .public) in a row): \(error, privacy: .public)")
                guard failures < maxAttempts else { throw error }
                progress(.retrying(attempt: failures + 1, maxAttempts: maxAttempts))
                try await Task.sleep(for: retryDelay * failures)
            }
        }
    }

    /// Whether the course has a point or a green that still has to be fetched.
    static func isNeeded(for course: Course, status: ElevationStatus) -> Bool {
        remaining(in: course, status: status) > 0
    }

    /// What USGS turned out not to have, in words for the user. Nil when it had everything.
    static func noDataMessage(from old: ElevationStatus, to new: ElevationStatus) -> String? {
        let points = new.pointsWithoutData.subtracting(old.pointsWithoutData).count
        let greens = new.greensWithoutData.filter { old.greensWithoutData[$0.key] != $0.value }.count
        var parts: [String] = []
        if points > 0 {
            parts.append("no elevation for \(points.formatted()) \(points == 1 ? "point" : "points")")
        }
        if greens > 0 {
            parts.append("no lidar data for \(greens.formatted()) \(greens == 1 ? "green" : "greens")")
        }
        return parts.isEmpty ? nil : "USGS has " + parts.joined(separator: " and ") + ". They are left empty."
    }

    /// How many points and greens are still to be fetched.
    static func remaining(in course: Course, status: ElevationStatus) -> Int {
        ElevationUpdater.missingCoordinates(in: course, status: status).count
            + GreenSurfaceUpdater.greensMissingSurface(in: course).filter { !status.hasNoData(forGreen: $0) }.count
    }
}

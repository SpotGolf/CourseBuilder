import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "ElevationWorker")

/// Fills in missing elevations for edited courses in the background.
///
/// Edits only need to leave the elevation of a point they add or move as `nil`. After a course
/// changes, the worker waits for edits to settle, finds every point with no elevation, looks them
/// up from USGS, and writes them into the current course. A point that moves while a lookup is
/// running no longer matches its result, so it stays `nil` and is looked up on the next pass.
///
/// USGS only covers the United States. Points it has no data for are set to sea level, the same
/// as the load-time prompt does, so the worker never leaves a point `nil` for good.
final class ElevationWorker: ObservableObject {
    enum Status: Equatable {
        case updating(points: Int)
        case setToSeaLevel(points: Int)
        case failed(message: String)

        var message: String {
            switch self {
            case .updating(let points):
                "Looking up elevations for \(points) \(points == 1 ? "point" : "points")..."
            case .setToSeaLevel(let points):
                "USGS has no elevation data for \(points) \(points == 1 ? "point" : "points"). Set to sea level."
            case .failed(let message):
                "Elevation lookup failed: \(message)"
            }
        }
    }

    typealias Fetch = @Sendable ([Coordinate]) async throws -> [Double?]

    static let usgsFetch: Fetch = { coordinates in
        try await USGSElevationClient().elevations(for: coordinates)
    }

    @Published private(set) var statuses: [UUID: Status] = [:]

    /// Returns the current version of a course. Set by the owner of the courses.
    var read: (UUID) -> Course? = { _ in nil }
    /// Changes the current version of a course in place. Set by the owner of the courses.
    var modify: (UUID, (inout Course) -> Void) -> Void = { _, _ in }

    private let fetch: Fetch
    private let debounce: Duration
    private let retryDelay: Duration
    private let maxAttempts: Int

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var fetching: Set<UUID> = []
    private var outsideUnitedStates: Set<UUID> = []

    init(
        fetch: @escaping Fetch = ElevationWorker.usgsFetch,
        debounce: Duration = .milliseconds(500),
        retryDelay: Duration = .seconds(5),
        maxAttempts: Int = 3
    ) {
        self.fetch = fetch
        self.debounce = debounce
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
    }

    /// Call on the main thread after every change to a course.
    func courseDidChange(_ id: UUID) {
        // A running lookup checks the course again when it finishes.
        guard !fetching.contains(id) else { return }
        tasks[id]?.cancel()
        let debounce = debounce
        tasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.run(id)
        }
    }

    /// Stops all work for a course, for example because it was deleted.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        fetching.remove(id)
        outsideUnitedStates.remove(id)
        setStatus(nil, for: id)
    }

    /// The current pass for a course. Tests await it.
    func task(for id: UUID) -> Task<Void, Never>? {
        tasks[id]
    }

    @MainActor
    private func run(_ id: UUID) async {
        setStatus(nil, for: id)
        var attempts = 0

        while !Task.isCancelled {
            guard let course = read(id) else { return }
            let missing = ElevationUpdater.missingCoordinates(in: course)
            guard !missing.isEmpty else { return }

            if outsideUnitedStates.contains(id) {
                setToSeaLevel(missing, in: id)
                continue
            }

            setStatus(.updating(points: missing.count), for: id)
            fetching.insert(id)
            let result: Result<[Double?], Error>
            do {
                result = .success(try await fetch(missing))
            } catch {
                result = .failure(error)
            }
            fetching.remove(id)
            guard !Task.isCancelled else { return }

            switch result {
            case .success(let elevations):
                let lookup = ElevationUpdater.resolve(missing, with: elevations)
                if lookup.seaLevelPoints == missing.count {
                    outsideUnitedStates.insert(id)
                }
                modify(id) { ElevationUpdater.apply(lookup.elevations, to: &$0) }
                setStatus(lookup.seaLevelPoints == 0 ? nil : .setToSeaLevel(points: lookup.seaLevelPoints), for: id)
                attempts = 0

            case .failure(let error as USGSElevationClient.ElevationError) where error.isOutsideUnitedStates:
                outsideUnitedStates.insert(id)
                setToSeaLevel(missing, in: id)

            case .failure(let error):
                attempts += 1
                logger.error("Elevation lookup failed (attempt \(attempts, privacy: .public)): \(error, privacy: .public)")
                guard attempts < maxAttempts else {
                    setStatus(.failed(message: error.localizedDescription), for: id)
                    return
                }
                try? await Task.sleep(for: retryDelay * attempts)
            }
        }
    }

    @MainActor
    private func setToSeaLevel(_ coordinates: [Coordinate], in id: UUID) {
        let lookup = ElevationUpdater.resolve(coordinates, with: [])
        modify(id) { ElevationUpdater.apply(lookup.elevations, to: &$0) }
        setStatus(.setToSeaLevel(points: coordinates.count), for: id)
    }

    /// Publishes only real changes, so observers do not redraw for nothing.
    private func setStatus(_ status: Status?, for id: UUID) {
        guard statuses[id] != status else { return }
        statuses[id] = status
    }
}

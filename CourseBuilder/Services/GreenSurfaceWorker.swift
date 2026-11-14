import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "GreenSurfaceWorker")

/// Builds missing green elevation surfaces for edited courses in the background.
///
/// An edit to a green's polygon clears its surface. After a course changes, the worker waits for
/// edits to settle, then samples each green with no surface from USGS, one green at a time, and
/// writes the surface into the current course. A green that is edited while it is being sampled
/// no longer matches its result, so it is sampled again on the next pass.
///
/// A surface is only built from 1 m lidar data, which USGS has for most of the United States.
/// Elsewhere it has coarser data or none. A green with no lidar data is left with no surface and is
/// not asked for again until its polygon changes.
final class GreenSurfaceWorker: ObservableObject {
    enum Status: Equatable {
        case updating(greens: Int)
        case noData(greens: Int)
        case failed(message: String)

        var message: String {
            switch self {
            case .updating(let greens):
                "Looking up elevations for \(greens) \(greens == 1 ? "green" : "greens")..."
            case .noData(let greens):
                "USGS has no lidar elevation data for \(greens) \(greens == 1 ? "green" : "greens"). Green heat maps are missing."
            case .failed(let message):
                "Green elevation lookup failed: \(message)"
            }
        }

        /// Whether the status tells the user that something is wrong.
        var isWarning: Bool {
            switch self {
            case .updating: false
            case .noData, .failed: true
            }
        }
    }

    @Published private(set) var statuses: [UUID: Status] = [:]

    /// Returns the current version of a course. Set by the owner of the courses.
    var read: (UUID) -> Course? = { _ in nil }
    /// Changes the current version of a course in place. Set by the owner of the courses.
    var modify: (UUID, (inout Course) -> Void) -> Void = { _, _ in }

    private let fetch: GreenSurfaceUpdater.Fetch
    private let debounce: Duration
    private let retryDelay: Duration
    private let maxAttempts: Int

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var fetching: Set<UUID> = []
    private var outsideUnitedStates: Set<UUID> = []
    /// The greens USGS has no lidar data for, with the positions they were sampled for.
    private var withoutData: [UUID: [Int: [ElevationUpdater.Location]]] = [:]

    init(
        fetch: @escaping GreenSurfaceUpdater.Fetch = GreenSurfaceUpdater.usgsFetch,
        debounce: Duration = .milliseconds(500),
        retryDelay: Duration = .seconds(5),
        maxAttempts: Int = 3
    ) {
        self.fetch = fetch
        self.debounce = debounce
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
    }

    /// Call on the main thread after every change to a course, and when a course is opened.
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
        withoutData[id] = nil
        setStatus(nil, for: id)
    }

    /// The current pass for a course. Tests await it.
    func task(for id: UUID) -> Task<Void, Never>? {
        tasks[id]
    }

    @MainActor
    private func run(_ id: UUID) async {
        var attempts = 0

        while !Task.isCancelled {
            guard let course = read(id) else { return }
            let missing = GreenSurfaceUpdater.greensMissingSurface(in: course)
            // Forget greens that were deleted, edited, or given a surface.
            let known = (withoutData[id] ?? [:]).filter { entry in
                missing.contains { $0.id == entry.key && GreenSurfaceUpdater.positions(of: $0.polygon) == entry.value }
            }
            withoutData[id] = known
            let pending = missing.filter { known[$0.id] == nil }

            guard let green = pending.first else {
                setStatus(known.isEmpty ? nil : .noData(greens: known.count), for: id)
                return
            }
            let sampled = GreenSurfaceUpdater.positions(of: green.polygon)

            if outsideUnitedStates.contains(id) {
                withoutData[id, default: [:]][green.id] = sampled
                continue
            }
            guard let grid = GreenSurfaceUpdater.grid(for: green.polygon) else { return }

            setStatus(.updating(greens: pending.count), for: id)
            fetching.insert(id)
            let result: Result<[USGSElevationClient.Sample?], Error>
            do {
                result = .success(try await fetch(grid.coordinates))
            } catch {
                result = .failure(error)
            }
            fetching.remove(id)
            guard !Task.isCancelled else { return }

            switch result {
            case .success(let samples):
                if let surface = GreenSurfaceUpdater.surface(for: grid, samples: samples) {
                    modify(id) { GreenSurfaceUpdater.apply(surface, toGreen: green.id, sampledFor: sampled, in: &$0) }
                } else {
                    withoutData[id, default: [:]][green.id] = sampled
                    if samples.allSatisfy({ $0 == nil }) {
                        outsideUnitedStates.insert(id)
                    }
                }
                attempts = 0

            case .failure(let error as USGSElevationClient.ElevationError) where error.isOutsideUnitedStates:
                outsideUnitedStates.insert(id)
                withoutData[id, default: [:]][green.id] = sampled

            case .failure(let error):
                attempts += 1
                logger.error("Green surface lookup failed (attempt \(attempts, privacy: .public)): \(error, privacy: .public)")
                guard attempts < maxAttempts else {
                    setStatus(.failed(message: error.localizedDescription), for: id)
                    return
                }
                try? await Task.sleep(for: retryDelay * attempts)
            }
        }
    }

    /// Publishes only real changes, so observers do not redraw for nothing.
    private func setStatus(_ status: Status?, for id: UUID) {
        guard statuses[id] != status else { return }
        statuses[id] = status
    }
}

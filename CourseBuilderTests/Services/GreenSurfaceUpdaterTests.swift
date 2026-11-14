import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("Green surface updater")
struct GreenSurfaceUpdaterTests {
    // MARK: - Grid mask

    @Test func gridCoversARectangleAndOneMeterAroundIt() throws {
        let grid = try #require(GreenSurfaceUpdater.grid(for: GreenFixtures.rectangle(width: 10.5, height: 6.5)))

        // 10.5 m by 6.5 m, plus 1 m on each side, at 1 m spacing.
        #expect(grid.columns == 13)
        #expect(grid.rows == 9)
        // Three corner cells are more than 1 m from the green. The north-east one is 0.7 m away.
        #expect(grid.mask.filter { $0 }.count == 13 * 9 - 3)
        #expect(!grid.isSampled(column: 0, row: 0))
        #expect(!grid.isSampled(column: 12, row: 0))
        #expect(!grid.isSampled(column: 0, row: 8))
        #expect(grid.isSampled(column: 12, row: 8))
        #expect(!grid.isSampled(column: 13, row: 4))
        #expect(grid.isSampled(column: 0, row: 4))
        #expect(grid.isSampled(column: 6, row: 0))
        #expect(grid.isSampled(column: 6, row: 4))
        #expect(grid.coordinates.count == 13 * 9 - 3)
    }

    @Test func gridOriginIsOneMeterSouthWestOfThePolygon() throws {
        let grid = try #require(GreenSurfaceUpdater.grid(for: GreenFixtures.rectangle(width: 10.5, height: 6.5)))

        let corner = grid.coordinate(column: 1, row: 1)
        #expect(abs(corner.lat - GreenFixtures.south) < 1e-9)
        #expect(abs(corner.lon - GreenFixtures.west) < 1e-9)
        #expect(grid.origin.lat < GreenFixtures.south)
        #expect(grid.origin.lon < GreenFixtures.west)
    }

    @Test func gridLeavesOutCellsFarFromAnLShapedGreen() throws {
        // An L: 10.5 m by 10.5 m with the north-east 6 m by 6 m corner cut away.
        let polygon = GreenFixtures.polygon(meters: [(0, 0), (10.5, 0), (10.5, 4.5), (4.5, 4.5), (4.5, 10.5), (0, 10.5)])
        let grid = try #require(GreenSurfaceUpdater.grid(for: polygon))

        // Grid cells are 1 m further east and north than the polygon's own meters.
        #expect(grid.isSampled(column: 3, row: 3))    // inside
        #expect(grid.isSampled(column: 9, row: 3))    // inside the east arm
        #expect(grid.isSampled(column: 3, row: 9))    // inside the north arm
        #expect(grid.isSampled(column: 0, row: 5))    // 1 m outside the west edge
        #expect(grid.isSampled(column: 9, row: 6))    // 0.5 m outside the inner edge
        #expect(!grid.isSampled(column: 9, row: 7))   // 1.5 m outside the inner edge
        #expect(grid.isSampled(column: 6, row: 6))    // 0.7 m from the inner corner
        #expect(!grid.isSampled(column: 7, row: 7))   // 2.1 m from the inner corner
        #expect(!grid.isSampled(column: 9, row: 9))   // deep in the cut-away corner
    }

    @Test func polygonThatIsNotAGreenHasNoGrid() {
        #expect(GreenSurfaceUpdater.grid(for: CoordinatePath()) == nil)
        #expect(GreenSurfaceUpdater.grid(for: GreenFixtures.polygon(meters: [(0, 0), (5, 5)])) == nil)
        #expect(GreenSurfaceUpdater.grid(for: GreenFixtures.rectangle(width: 500, height: 500)) == nil)
    }

    // MARK: - Updater with a stubbed client

    @Test func updateBuildsASurfaceForEachGreenWithoutOne() async throws {
        let existing = ElevationSurface(origin: Coordinate(lat: 1, lon: 1), columns: 1, elevations: [7])
        let course = GreenFixtures.course(features: [
            Feature(id: 1, type: .green, polygon: GreenFixtures.rectangle(width: 10.5, height: 6.5)),
            Feature(id: 2, type: .green, polygon: GreenFixtures.rectangle(width: 4, height: 4), surface: existing),
            Feature(id: 3, type: .bunker, polygon: GreenFixtures.rectangle(width: 4, height: 4)),
        ])
        let log = GreenFetchLog()

        let update = try await GreenSurfaceUpdater.update(course) { coordinates in
            await log.record(coordinates)
            return coordinates.map { _ in lidar(1600.25) }
        }

        let surface = try #require(update.course.features[0].surface)
        #expect(update.greensWithoutData == 0)
        #expect(surface.columns == 13)
        #expect(surface.rows == 9)
        #expect(surface.spacing == 1)
        #expect(surface.elevation(column: 6, row: 4) == 1600.25)
        #expect(surface.elevation(column: 0, row: 0) == nil)
        #expect(update.course.features[1].surface == existing)
        #expect(update.course.features[2].surface == nil)
        #expect(await log.requests.map(\.count) == [13 * 9 - 3])
    }

    @Test func surfaceKeepsEachElevationInItsCell() throws {
        let grid = try #require(GreenSurfaceUpdater.grid(for: GreenFixtures.rectangle(width: 3.5, height: 2.5)))
        let elevations = grid.coordinates.indices.map { Double($0) }

        let surface = try #require(GreenSurfaceUpdater.surface(for: grid, elevations: elevations))

        // Row 0 has no corner cells, so its first sampled cell is column 1.
        #expect(surface.elevation(column: 0, row: 0) == nil)
        #expect(surface.elevation(column: 1, row: 0) == 0)
        #expect(surface.elevation(column: 0, row: 1) == Double(grid.columns - 2))
    }

    @Test func greenWithoutLidarDataIsLeftWithNoSurface() async throws {
        let course = GreenFixtures.course(features: [
            Feature(id: 1, type: .green, polygon: GreenFixtures.rectangle(width: 4, height: 4)),
        ])

        let noSamples = try await GreenSurfaceUpdater.update(course) { $0.map { _ in nil } }
        let oneMissing = try await GreenSurfaceUpdater.update(course) { coordinates in
            coordinates.indices.map { $0 == 0 ? nil : lidar(10) }
        }
        // 1/3 arc-second data, about 10 m, as USGS has for Vancouver.
        let coarse = try await GreenSurfaceUpdater.update(course) { coordinates in
            coordinates.map { _ in USGSElevationClient.Sample(elevation: 60, resolution: 10.3) }
        }
        let oneCoarse = try await GreenSurfaceUpdater.update(course) { coordinates in
            coordinates.indices.map { $0 == 0 ? USGSElevationClient.Sample(elevation: 10, resolution: 5) : lidar(10) }
        }
        let unknownResolution = try await GreenSurfaceUpdater.update(course) { coordinates in
            coordinates.map { _ in USGSElevationClient.Sample(elevation: 10, resolution: nil) }
        }
        let rejected = try await GreenSurfaceUpdater.update(course) { _ in
            throw USGSElevationClient.ElevationError.requestRejected(message: "Outside coverage.")
        }

        for update in [noSamples, oneMissing, rejected, coarse, oneCoarse, unknownResolution] {
            #expect(update.course.features[0].surface == nil)
            #expect(update.greensWithoutData == 1)
        }
    }

    @Test func serviceErrorsAreThrown() async {
        let course = GreenFixtures.course(features: [
            Feature(id: 1, type: .green, polygon: GreenFixtures.rectangle(width: 4, height: 4)),
        ])

        await #expect(throws: USGSElevationClient.ElevationError.self) {
            _ = try await GreenSurfaceUpdater.update(course) { _ in
                throw USGSElevationClient.ElevationError.serverError(statusCode: 504)
            }
        }
    }

    // MARK: - Clearing the surface after a polygon edit

    @Test func editingAGreenPolygonClearsItsSurface() {
        let old = GreenFixtures.courseWithSurfaces()
        var edited = old
        var polygon = Array(edited.features[0].polygon)
        polygon[0].lat += 0.00001
        polygon[0].ele = nil
        edited.features[0].polygon = CoordinatePath(polygon)

        GreenSurfaceUpdater.clearStaleSurfaces(in: &edited, comparedTo: old)

        #expect(edited.features[0].surface == nil)
        #expect(edited.features[1].surface != nil)
    }

    @Test func fillingInPointElevationsKeepsTheSurface() {
        let old = GreenFixtures.courseWithSurfaces()
        var edited = old
        edited.features[0].polygon = CoordinatePath(edited.features[0].polygon.map {
            Coordinate(lat: $0.lat, lon: $0.lon, ele: 12)
        })

        GreenSurfaceUpdater.clearStaleSurfaces(in: &edited, comparedTo: old)

        #expect(edited.features[0].surface != nil)
    }

    @Test func undoThatBringsBackAPolygonWithItsSurfaceKeepsTheSurface() {
        let original = GreenFixtures.courseWithSurfaces()
        var current = original
        current.features[0].polygon = GreenFixtures.rectangle(width: 8, height: 8)
        current.features[0].surface = nil
        var undone = current
        undone.features[0] = original.features[0]

        GreenSurfaceUpdater.clearStaleSurfaces(in: &undone, comparedTo: current)

        #expect(undone.features[0].surface == original.features[0].surface)
    }

    @Test func surfaceForAnEditedPolygonIsNotApplied() throws {
        var course = GreenFixtures.course(features: [
            Feature(id: 1, type: .green, polygon: GreenFixtures.rectangle(width: 4, height: 4)),
        ])
        let sampled = GreenSurfaceUpdater.positions(of: course.features[0].polygon)
        let surface = ElevationSurface(origin: Coordinate(lat: 1, lon: 1), columns: 1, elevations: [7])
        course.features[0].polygon = GreenFixtures.rectangle(width: 5, height: 4)

        #expect(!GreenSurfaceUpdater.apply(surface, toGreen: 1, sampledFor: sampled, in: &course))
        #expect(course.features[0].surface == nil)
    }

    @MainActor
    @Test func storeClearsTheSurfaceWhenAGreenIsEditedThroughABinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CourseStore(
            directory: directory,
            elevationWorker: ElevationWorker(fetch: { $0.map { _ in 1 } }),
            greenSurfaceWorker: GreenSurfaceWorker(fetch: { $0.map { _ in nil } })
        )
        let course = GreenFixtures.courseWithSurfaces()
        try store.save(course)
        let binding = try #require(store.binding(for: course.id))

        var edited = binding.wrappedValue
        edited.name = "Renamed"
        binding.wrappedValue = edited
        #expect(binding.wrappedValue.features[0].surface != nil)

        edited.features[0].polygon = GreenFixtures.rectangle(width: 8, height: 8)
        binding.wrappedValue = edited

        #expect(binding.wrappedValue.features[0].surface == nil)
        #expect(binding.wrappedValue.features[1].surface != nil)
        store.greenSurfaceWorker.cancel(course.id)
        store.elevationWorker.cancel(course.id)
    }

    // MARK: - Export warnings

    @Test func exportWarnsWhenNoGreenHasASurface() {
        var course = GreenFixtures.courseWithSurfaces()
        course.features[0].surface = nil
        course.features[1].surface = nil

        let warnings = CourseIntegrity.greenSurfaceWarnings(for: course)

        #expect(warnings.count == 1)
        #expect(warnings[0].hasPrefix("No green has lidar elevation data"))
        #expect(CourseIntegrity.validateCourse(course).contains(warnings[0]))
    }

    @Test func exportWarnsWhenOnlySomeHolesHaveASurface() {
        var course = GreenFixtures.courseWithSurfaces()
        course.features[1].surface = nil

        let warnings = CourseIntegrity.greenSurfaceWarnings(for: course)

        #expect(warnings.count == 1)
        #expect(warnings[0].hasPrefix("Hole 2: no green lidar elevation data, but other holes have it. Fix this before exporting"))
    }

    @Test func exportDoesNotWarnWhenEveryGreenHasASurface() {
        #expect(CourseIntegrity.greenSurfaceWarnings(for: GreenFixtures.courseWithSurfaces()).isEmpty)
    }
}

@MainActor
@Suite("Green surface worker")
struct GreenSurfaceWorkerTests {
    @Test func buildsMissingSurfacesInTheBackground() async {
        let log = GreenFetchLog()
        let box = GreenCourseBox(GreenFixtures.courseWithoutSurfaces())
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            return coordinates.map { _ in lidar(100) }
        }

        await change(box, worker)

        #expect(box.course.features.allSatisfy { $0.surface != nil })
        #expect(await log.requests.count == 2)
        #expect(worker.statuses[box.course.id] == nil)
    }

    @Test func courseOutsideUnitedStatesAsksOnceAndWarns() async {
        let log = GreenFetchLog()
        let box = GreenCourseBox(GreenFixtures.courseWithoutSurfaces())
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            throw USGSElevationClient.ElevationError.requestRejected(message: "Outside coverage.")
        }

        await change(box, worker)
        await change(box, worker)

        #expect(box.course.features.allSatisfy { $0.surface == nil })
        #expect(await log.requests.count == 1)
        #expect(worker.statuses[box.course.id] == .noData(greens: 2))
    }

    @Test func courseWithCoarseDataGetsNoSurfacesAndWarns() async {
        let log = GreenFetchLog()
        let box = GreenCourseBox(GreenFixtures.courseWithoutSurfaces())
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            return coordinates.map { _ in USGSElevationClient.Sample(elevation: 86, resolution: 5) }
        }

        await change(box, worker)
        await change(box, worker)

        #expect(box.course.features.allSatisfy { $0.surface == nil })
        // Each green is asked for once. Lidar coverage can end part way across a course.
        #expect(await log.requests.count == 2)
        #expect(worker.statuses[box.course.id] == .noData(greens: 2))
    }

    @Test func greenEditedDuringLookupIsSampledAgain() async {
        let log = GreenFetchLog()
        var course = GreenFixtures.courseWithoutSurfaces()
        course.features.removeLast()
        let box = GreenCourseBox(course)
        let worker = makeWorker(box: box) { coordinates in
            if await log.requests.isEmpty {
                await MainActor.run { box.course.features[0].polygon = GreenFixtures.rectangle(width: 3.5, height: 2.5) }
            }
            await log.record(coordinates)
            return coordinates.map { _ in lidar(100) }
        }

        await change(box, worker)

        #expect(await log.requests.count == 2)
        #expect(box.course.features[0].surface?.columns == 6)
    }

    @Test func failuresAreRetriedThenReported() async {
        let log = GreenFetchLog()
        let box = GreenCourseBox(GreenFixtures.courseWithoutSurfaces())
        let worker = makeWorker(box: box, maxAttempts: 2) { coordinates in
            await log.record(coordinates)
            throw USGSElevationClient.ElevationError.serverError(statusCode: 504)
        }

        await change(box, worker)

        #expect(await log.requests.count == 2)
        guard case .failed = worker.statuses[box.course.id] else {
            Issue.record("Expected a failed status")
            return
        }
    }

    private func change(_ box: GreenCourseBox, _ worker: GreenSurfaceWorker) async {
        worker.courseDidChange(box.course.id)
        await worker.task(for: box.course.id)?.value
    }

    private func makeWorker(
        box: GreenCourseBox,
        maxAttempts: Int = 3,
        fetch: @escaping GreenSurfaceUpdater.Fetch
    ) -> GreenSurfaceWorker {
        let worker = GreenSurfaceWorker(fetch: fetch, debounce: .zero, retryDelay: .zero, maxAttempts: maxAttempts)
        worker.read = { _ in box.course }
        worker.modify = { _, change in change(&box.course) }
        return worker
    }
}

/// A sample from 1 m lidar data.
private func lidar(_ elevation: Double) -> USGSElevationClient.Sample {
    USGSElevationClient.Sample(elevation: elevation, resolution: 1)
}

private enum GreenFixtures {
    static let south = 39.0
    static let west = -105.0

    /// A polygon from points given in meters east and north of (`south`, `west`). A path snaps
    /// its points to about 0.3 m, so sizes ending in .5 keep every cell clear of the 1 m limit.
    static func polygon(meters points: [(Double, Double)]) -> CoordinatePath {
        let metersPerDegreeLongitude = GreenSurfaceUpdater.metersPerDegree * cos(south * .pi / 180)
        return CoordinatePath(points.map { x, y in
            Coordinate(lat: south + y / GreenSurfaceUpdater.metersPerDegree, lon: west + x / metersPerDegreeLongitude, ele: 1600)
        })
    }

    static func rectangle(width: Double, height: Double) -> CoordinatePath {
        polygon(meters: [(0, 0), (width, 0), (width, height), (0, height)])
    }

    static func course(features: [Feature], holes: [Hole] = [Hole(number: 1, par: 4)]) -> Course {
        Course(
            name: "Test Course",
            location: CourseLocation(
                address: "", city: "Denver", state: "CO", country: "US",
                coordinate: Coordinate(lat: south, lon: west, ele: 1600)
            ),
            features: features,
            subCourses: [SubCourse(name: "Front", holes: holes)]
        )
    }

    /// Two holes, each with one green that has no surface.
    static func courseWithoutSurfaces() -> Course {
        var first = Hole(number: 1, par: 4)
        first.features = [1]
        var second = Hole(number: 2, par: 3)
        second.features = [2]
        return course(
            features: [
                Feature(id: 1, type: .green, polygon: rectangle(width: 10, height: 6)),
                Feature(id: 2, type: .green, polygon: rectangle(width: 4, height: 4)),
            ],
            holes: [first, second]
        )
    }

    /// Two holes, each with one green that has a surface.
    static func courseWithSurfaces() -> Course {
        var course = courseWithoutSurfaces()
        for index in course.features.indices {
            let grid = GreenSurfaceUpdater.grid(for: course.features[index].polygon)!
            course.features[index].surface = GreenSurfaceUpdater.surface(
                for: grid,
                elevations: grid.coordinates.map { _ in 1600 }
            )
        }
        return course
    }
}

private final class GreenCourseBox {
    var course: Course
    init(_ course: Course) { self.course = course }
}

private actor GreenFetchLog {
    private(set) var requests: [[Coordinate]] = []
    func record(_ coordinates: [Coordinate]) { requests.append(coordinates) }
}

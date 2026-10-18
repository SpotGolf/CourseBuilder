import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@MainActor
@Suite("Elevation worker")
struct ElevationWorkerTests {
    @Test func fillsMissingElevationsAndKeepsExistingOnes() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [
            Coordinate(latitude: 39.1, longitude: -105.0),
            Coordinate(latitude: 39.2, longitude: -105.0, elevation: 5),
        ]))
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            return coordinates.map { $0.latitude * 10 }
        }

        await change(box, worker)

        #expect(box.course.location.coordinate.elevation == 390)
        #expect(box.course.features[0].polygon.map(\.elevation) == [391, 5])
        #expect(await log.requests.count == 1)
        #expect(worker.statuses[box.course.id] == nil)
    }

    @Test func changesDuringTheWaitShareOneLookup() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [Coordinate(latitude: 39.1, longitude: -105.0)]))
        let worker = makeWorker(box: box, debounce: .milliseconds(50)) { coordinates in
            await log.record(coordinates)
            return coordinates.map { _ in 1 }
        }

        worker.courseDidChange(box.course.id)
        box.course.features[0].polygon.append(Coordinate(latitude: 39.2, longitude: -105.0))
        await change(box, worker)

        #expect(await log.requests.count == 1)
        #expect(!box.course.isMissingElevations)
    }

    @Test func pointMovedDuringLookupIsLookedUpAgain() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [Coordinate(latitude: 39.1, longitude: -105.0)]))
        let moved = Coordinate(latitude: 39.5, longitude: -105.0)
        let worker = makeWorker(box: box) { coordinates in
            if await log.requests.isEmpty {
                await MainActor.run { box.course.features[0].polygon[0] = moved }
            }
            await log.record(coordinates)
            return coordinates.map { $0.latitude * 10 }
        }

        await change(box, worker)

        #expect(box.course.features[0].polygon[0].elevation == 395)
        #expect(await log.requests.count == 2)
        #expect(await log.requests[1] == [moved])
    }

    @Test func pointsWithoutDataAreSetToSeaLevel() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [
            Coordinate(latitude: 39.1, longitude: -105.0),
            Coordinate(latitude: 39.2, longitude: -105.0),
        ]))
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            return coordinates.map { $0.latitude == 39.2 ? nil : 100 }
        }

        await change(box, worker)

        #expect(box.course.features[0].polygon.map(\.elevation) == [100, 0])
        #expect(worker.statuses[box.course.id] == .setToSeaLevel(points: 1))
    }

    @Test func courseOutsideUnitedStatesStopsAskingUSGS() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [Coordinate(latitude: 56.3, longitude: -2.8)]))
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            throw USGSElevationClient.ElevationError.requestRejected(message: "Out of extent.")
        }

        await change(box, worker)
        #expect(!box.course.isMissingElevations)

        box.course.features[0].polygon.append(Coordinate(latitude: 56.4, longitude: -2.8))
        await change(box, worker)

        #expect(box.course.features[0].polygon[1].elevation == 0)
        #expect(await log.requests.count == 1)
    }

    @Test func failuresAreRetriedThenReported() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: []))
        let worker = makeWorker(box: box, maxAttempts: 3) { coordinates in
            await log.record(coordinates)
            throw URLError(.notConnectedToInternet)
        }

        await change(box, worker)

        #expect(await log.requests.count == 3)
        #expect(box.course.location.coordinate.elevation == nil)
        guard case .failed = worker.statuses[box.course.id] else {
            Issue.record("Expected a failed status")
            return
        }
    }

    @Test func courseWithNoMissingPointsMakesNoRequest() async {
        let log = FetchLog()
        var course = makeCourse(polygon: [Coordinate(latitude: 39.1, longitude: -105.0, elevation: 5)])
        course.location.coordinate.elevation = 1600
        let box = CourseBox(course)
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            return coordinates.map { _ in 1 }
        }

        await change(box, worker)

        #expect(await log.requests.isEmpty)
    }

    // MARK: - Helpers

    private func change(_ box: CourseBox, _ worker: ElevationWorker) async {
        worker.courseDidChange(box.course.id)
        await worker.task(for: box.course.id)?.value
    }

    private func makeWorker(
        box: CourseBox,
        debounce: Duration = .zero,
        maxAttempts: Int = 3,
        fetch: @escaping ElevationWorker.Fetch
    ) -> ElevationWorker {
        let worker = ElevationWorker(fetch: fetch, debounce: debounce, retryDelay: .zero, maxAttempts: maxAttempts)
        worker.read = { _ in box.course }
        worker.modify = { _, change in change(&box.course) }
        return worker
    }

    private func makeCourse(polygon: [Coordinate]) -> Course {
        Course(
            name: "Test Course",
            location: CourseLocation(
                address: "", city: "Denver", state: "CO", country: "US",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            ),
            features: [Feature(id: 1, type: .green, polygon: polygon)],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])]
        )
    }
}

private final class CourseBox {
    var course: Course
    init(_ course: Course) { self.course = course }
}

private actor FetchLog {
    private(set) var requests: [[Coordinate]] = []
    func record(_ coordinates: [Coordinate]) { requests.append(coordinates) }
}

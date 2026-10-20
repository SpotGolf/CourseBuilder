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
            Coordinate(lat: 39.1, lon: -105.0),
            Coordinate(lat: 39.2, lon: -105.0, ele: 5),
        ]))
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            return coordinates.map { $0.lat * 10 }
        }

        await change(box, worker)

        #expect(box.course.location.coordinate.ele == 390)
        #expect(box.course.features[0].polygon.compactMap(\.ele) == [391, 5].map(pathElevation))
        #expect(await log.requests.count == 1)
        #expect(worker.statuses[box.course.id] == nil)
    }

    @Test func changesDuringTheWaitShareOneLookup() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [Coordinate(lat: 39.1, lon: -105.0)]))
        let worker = makeWorker(box: box, debounce: .milliseconds(50)) { coordinates in
            await log.record(coordinates)
            return coordinates.map { _ in 1 }
        }

        worker.courseDidChange(box.course.id)
        box.course.features[0].polygon.append(Coordinate(lat: 39.2, lon: -105.0))
        await change(box, worker)

        #expect(await log.requests.count == 1)
        #expect(!box.course.isMissingElevations)
    }

    @Test func pointMovedDuringLookupIsLookedUpAgain() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [Coordinate(lat: 39.1, lon: -105.0)]))
        let moved = Coordinate(lat: 39.5, lon: -105.0)
        let worker = makeWorker(box: box) { coordinates in
            if await log.requests.isEmpty {
                await MainActor.run { box.course.features[0].polygon = [moved] }
            }
            await log.record(coordinates)
            return coordinates.map { $0.lat * 10 }
        }

        await change(box, worker)

        #expect(box.course.features[0].polygon[0].ele == pathElevation(395))
        #expect(await log.requests.count == 2)
        #expect(await log.requests[1] == [moved])
    }

    @Test func pointsWithoutDataAreSetToSeaLevel() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [
            Coordinate(lat: 39.1, lon: -105.0),
            Coordinate(lat: 39.2, lon: -105.0),
        ]))
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            return coordinates.map { $0.lat == 39.2 ? nil : 100 }
        }

        await change(box, worker)

        #expect(box.course.features[0].polygon.compactMap(\.ele) == [100, 0].map(pathElevation))
        #expect(worker.statuses[box.course.id] == .setToSeaLevel(points: 1))
    }

    @Test func courseOutsideUnitedStatesStopsAskingUSGS() async {
        let log = FetchLog()
        let box = CourseBox(makeCourse(polygon: [Coordinate(lat: 56.3, lon: -2.8)]))
        let worker = makeWorker(box: box) { coordinates in
            await log.record(coordinates)
            throw USGSElevationClient.ElevationError.requestRejected(message: "Out of extent.")
        }

        await change(box, worker)
        #expect(!box.course.isMissingElevations)

        box.course.features[0].polygon.append(Coordinate(lat: 56.4, lon: -2.8))
        await change(box, worker)

        #expect(box.course.features[0].polygon[1].ele == 0)
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
        #expect(box.course.location.coordinate.ele == nil)
        guard case .failed = worker.statuses[box.course.id] else {
            Issue.record("Expected a failed status")
            return
        }
    }

    @Test func courseWithNoMissingPointsMakesNoRequest() async {
        let log = FetchLog()
        var course = makeCourse(polygon: [Coordinate(lat: 39.1, lon: -105.0, ele: 5)])
        course.location.coordinate.ele = 1600
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

    private func makeCourse(polygon: CoordinatePath) -> Course {
        Course(
            name: "Test Course",
            location: CourseLocation(
                address: "", city: "Denver", state: "CO", country: "US",
                coordinate: Coordinate(lat: 39.0, lon: -105.0)
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

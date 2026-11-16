import XCTest
@testable import CourseBuilder
import CourseDataSwift

final class ElevationUpdaterTests: XCTestCase {
    override func tearDown() {
        StubUSGSProtocol.handler = nil
        StubUSGSProtocol.requestCount = 0
        super.tearDown()
    }

    // MARK: - missingCoordinates

    func testCourseWithoutPointsIsOnlyMissingItsLocation() {
        let course = makeCourse(features: [], centerline: [])
        XCTAssertEqual(ElevationUpdater.missingCoordinates(in: course), [course.location.coordinate])
    }

    func testPolygonPointLackingElevationIsMissing() {
        let point = Coordinate(lat: 39.1, lon: -105.1)
        let feature = Feature(id: 1, type: .green, polygon: [Coordinate(lat: 39.2, lon: -105.2, ele: 1600), point])
        let course = makeCourse(features: [feature], centerline: [])
        XCTAssertEqual(ElevationUpdater.missingCoordinates(in: course), [course.location.coordinate, point])
    }

    func testCenterlinePointLackingElevationIsMissing() {
        let point = Coordinate(lat: 39.1, lon: -105.1)
        let course = makeCourse(features: [], centerline: [point])
        XCTAssertEqual(ElevationUpdater.missingCoordinates(in: course), [course.location.coordinate, point])
    }

    func testPointsWithElevationsAreNotMissing() {
        let feature = Feature(id: 1, type: .green, polygon: [Coordinate(lat: 39.1, lon: -105.1, ele: 1600)])
        let centerline: CoordinatePath = [Coordinate(lat: 39.2, lon: -105.2, ele: 1601)]
        let course = makeCourse(features: [feature], centerline: centerline)
        XCTAssertEqual(ElevationUpdater.missingCoordinates(in: course), [course.location.coordinate])
    }

    func testPointKnownToHaveNoDataIsNotMissing() {
        let point = Coordinate(lat: 39.1, lon: -105.1)
        let course = makeCourse(features: [Feature(id: 1, type: .green, polygon: [point])], centerline: [])
        var status = ElevationStatus()
        XCTAssertEqual(ElevationUpdater.missingCoordinates(in: course, status: status), [course.location.coordinate, point])

        status.pointsWithoutData = [ElevationUpdater.Location(point)]

        XCTAssertEqual(ElevationUpdater.missingCoordinates(in: course, status: status), [course.location.coordinate])
    }

    // MARK: - fetchMissingElevations

    @MainActor
    func testFetchFillsEveryMissingElevationAndKeepsExistingOnes() async throws {
        // Elevation is derived from the point so the test can check each value landed on the right point.
        StubUSGSProtocol.handler = { points in
            points.enumerated().map { index, point in (locationId: index, value: point[1] * 10) }
        }
        let feature = Feature(id: 1, type: .green, polygon: [
            Coordinate(lat: 39.1, lon: -105.0),
            Coordinate(lat: 39.2, lon: -105.0, ele: 5),
            Coordinate(lat: 39.3, lon: -105.0),
        ])
        var course = makeCourse(features: [feature], centerline: [Coordinate(lat: 39.4, lon: -105.0)])
        var status = ElevationStatus()

        let found = try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status, fetch: makeFetch())

        XCTAssertEqual(found, 4)
        XCTAssertTrue(status.isEmpty)
        XCTAssertTrue(ElevationUpdater.missingCoordinates(in: course).isEmpty)
        XCTAssertEqual(course.location.coordinate.ele, 390)
        XCTAssertEqual(course.features[0].polygon.compactMap(\.ele), [391, 5, 393].map(pathElevation))
        XCTAssertEqual(course.centerlinePath(for: course.subCourses[0].holes[0])[0].ele, pathElevation(394))
    }

    @MainActor
    func testFetchSplitsLargeCoursesIntoBatchesAndReportsProgress() async throws {
        StubUSGSProtocol.handler = { points in
            points.enumerated().map { index, point in (locationId: index, value: point[1]) }
        }
        let count = USGSElevationClient.batchSize * 2 + 5
        let polygon = (0..<count).map { Coordinate(lat: Double($0), lon: -105.0) }
        var course = makeCourse(features: [Feature(id: 1, type: .fairway, polygon: CoordinatePath(polygon))], centerline: [])
        var status = ElevationStatus()
        var progress: [Int] = []

        try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status, fetch: makeFetch()) { completed, total in
            XCTAssertEqual(total, count)
            progress.append(completed)
        }

        // The course location is one of the polygon's points, and each position is asked for once.
        XCTAssertEqual(StubUSGSProtocol.requestCount, 3)
        XCTAssertEqual(progress, [0, 200, 400, count])
        XCTAssertEqual(course.features[0].polygon.compactMap(\.ele), (0..<count).map { pathElevation(Double($0)) })
    }

    @MainActor
    func testFetchLeavesPointsWithoutDataEmptyAndRemembersThem() async throws {
        StubUSGSProtocol.handler = { points in
            points.indices.dropLast().map { (locationId: $0, value: 100) }
        }
        let point = Coordinate(lat: 56.3, lon: -2.8)
        var course = makeCourse(features: [Feature(id: 1, type: .green, polygon: [point])], centerline: [])
        var status = ElevationStatus()

        let found = try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status, fetch: makeFetch())

        XCTAssertEqual(found, 1)
        XCTAssertEqual(course.location.coordinate.ele, 100)
        XCTAssertNil(course.features[0].polygon[0].ele)
        XCTAssertEqual(status.pointsWithoutData, [ElevationUpdater.Location(point)])

        // The point is not asked for again.
        StubUSGSProtocol.requestCount = 0
        let again = try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status, fetch: makeFetch())
        XCTAssertEqual(again, 0)
        XCTAssertEqual(StubUSGSProtocol.requestCount, 0)
    }

    @MainActor
    func testFetchMakesNoRequestWhenNothingIsMissing() async throws {
        var course = makeCourse(features: [], centerline: [])
        course.location.coordinate.ele = 1600
        let original = course
        var status = ElevationStatus()

        try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status, fetch: makeFetch())

        XCTAssertEqual(course, original)
        XCTAssertEqual(StubUSGSProtocol.requestCount, 0)
    }

    // MARK: - isOutsideUnitedStates

    func testIsOutsideUnitedStates() {
        typealias ElevationError = USGSElevationClient.ElevationError
        XCTAssertTrue(ElevationError.requestRejected(message: "Out of extent.").isOutsideUnitedStates)
        XCTAssertTrue(ElevationError.noData(missing: 3, total: 3).isOutsideUnitedStates)
        XCTAssertFalse(ElevationError.noData(missing: 1, total: 3).isOutsideUnitedStates)
        XCTAssertFalse(ElevationError.serverError(statusCode: 504).isOutsideUnitedStates)
        XCTAssertFalse(ElevationError.invalidResponse.isOutsideUnitedStates)
    }

    // MARK: - Helpers

    private func makeFetch() -> ElevationUpdater.Fetch {
        let client = makeClient()
        return { try await client.elevations(for: $0) }
    }

    private func makeClient() -> USGSElevationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubUSGSProtocol.self]
        return USGSElevationClient(session: URLSession(configuration: configuration))
    }

    private func makeCourse(features: [Feature], centerline: CoordinatePath) -> Course {
        var course = Course(
            name: "Test Course",
            location: CourseLocation(
                address: "", city: "Denver", state: "CO", country: "US",
                coordinate: Coordinate(lat: 39.0, lon: -105.0)
            ),
            features: features,
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])]
        )
        course.setCenterline(centerline, subCourseIndex: 0, holeIndex: 0)
        return course
    }
}

/// Answers `getSamples` requests with the samples produced by `handler` for the requested points.
private final class StubUSGSProtocol: URLProtocol {
    static var handler: ((_ points: [[Double]]) -> [(locationId: Int, value: Double)])?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let samples = (Self.handler?(requestedPoints()) ?? []).map {
            ["locationId": $0.locationId, "value": String($0.value), "resolution": 1] as [String: Any]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["samples": samples])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestedPoints() -> [[Double]] {
        guard let stream = request.httpBodyStream else { return [] }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            body.append(buffer, count: read)
        }

        var components = URLComponents()
        components.percentEncodedQuery = String(data: body, encoding: .utf8)
        guard let geometry = components.queryItems?.first(where: { $0.name == "geometry" })?.value,
              let json = try? JSONSerialization.jsonObject(with: Data(geometry.utf8)) as? [String: Any] else { return [] }
        return json["points"] as? [[Double]] ?? []
    }
}

final class ElevationUpdaterLocationTests: XCTestCase {
    func testMissingCoordinatesListsEachPositionOnce() {
        let shared = Coordinate(lat: 39.1, lon: -105.0)
        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 39.0, lon: -105.0, ele: 1)),
            features: [
                Feature(id: 1, type: .green, polygon: [shared, Coordinate(lat: 39.2, lon: -105.0, ele: 2)]),
                Feature(id: 2, type: .bunker, polygon: [shared]),
            ],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])]
        )
        course.setCenterline([Coordinate(lat: 39.3, lon: -105.0)], subCourseIndex: 0, holeIndex: 0)

        XCTAssertEqual(ElevationUpdater.missingCoordinates(in: course), [shared, Coordinate(lat: 39.3, lon: -105.0)])

        ElevationUpdater.apply([
            ElevationUpdater.Location(shared): 10,
            ElevationUpdater.Location(Coordinate(lat: 39.2, lon: -105.0)): 99,
            ElevationUpdater.Location(Coordinate(lat: 50, lon: 50)): 7,
        ], to: &course)

        XCTAssertEqual(course.features[0].polygon.compactMap(\.ele), [10, 2].map(pathElevation))
        XCTAssertEqual(course.features[1].polygon.compactMap(\.ele), [pathElevation(10)])
        XCTAssertNil(course.centerlinePath(for: course.subCourses[0].holes[0])[0].ele)
    }
}

@MainActor
final class FetchMissingElevationsTests: XCTestCase {
    func testCourseOutsideUnitedStatesIsLeftEmptyAndRemembered() async throws {
        var course = makeCourse()
        var status = ElevationStatus()

        let found = try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status) { _ in
            throw USGSElevationClient.ElevationError.requestRejected(message: "Out of extent.")
        }

        XCTAssertEqual(found, 0)
        XCTAssertNil(course.location.coordinate.ele)
        XCTAssertTrue(course.features[0].polygon.allSatisfy { $0.ele == nil })
        XCTAssertEqual(status.pointsWithoutData.count, 3)
        XCTAssertTrue(ElevationUpdater.missingCoordinates(in: course, status: status).isEmpty)
    }

    func testServerErrorIsThrown() async {
        var course = makeCourse()
        var status = ElevationStatus()
        do {
            try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status) { _ in
                throw USGSElevationClient.ElevationError.serverError(statusCode: 503)
            }
            XCTFail("Expected serverError")
        } catch USGSElevationClient.ElevationError.serverError(let statusCode) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(status.isEmpty)
    }

    func testNetworkErrorIsThrown() async {
        var course = makeCourse()
        var status = ElevationStatus()
        do {
            try await ElevationUpdater.fetchMissingElevations(in: &course, status: &status) { _ in
                throw URLError(.cannotConnectToHost)
            }
            XCTFail("Expected URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeCourse() -> Course {
        Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 39.0, lon: -105.0)),
            features: [Feature(id: 1, type: .green, polygon: [
                Coordinate(lat: 39.1, lon: -105.0),
                Coordinate(lat: 39.2, lon: -105.0),
            ])]
        )
    }
}

import XCTest
@testable import CourseBuilder
import CourseDataSwift

final class ElevationUpdaterTests: XCTestCase {
    override func tearDown() {
        StubUSGSProtocol.handler = nil
        StubUSGSProtocol.requestCount = 0
        super.tearDown()
    }

    // MARK: - isMissingElevations

    func testCourseWithoutPointsIsNotMissingElevations() {
        XCTAssertFalse(makeCourse(features: [], centerline: []).isMissingElevations)
    }

    func testCourseWithPolygonPointLackingElevationIsMissingElevations() {
        let feature = Feature(id: 1, type: .green, polygon: [
            Coordinate(latitude: 39.0, longitude: -105.0, elevation: 1600),
            Coordinate(latitude: 39.1, longitude: -105.1),
        ])
        XCTAssertTrue(makeCourse(features: [feature], centerline: []).isMissingElevations)
    }

    func testCourseWithCenterlinePointLackingElevationIsMissingElevations() {
        let centerline = [Coordinate(latitude: 39.0, longitude: -105.0)]
        XCTAssertTrue(makeCourse(features: [], centerline: centerline).isMissingElevations)
    }

    func testCourseWithAllElevationsIsNotMissingElevations() {
        let feature = Feature(id: 1, type: .green, polygon: [Coordinate(latitude: 39.0, longitude: -105.0, elevation: 1600)])
        let centerline = [Coordinate(latitude: 39.0, longitude: -105.0, elevation: 1601)]
        XCTAssertFalse(makeCourse(features: [feature], centerline: centerline).isMissingElevations)
    }

    // MARK: - update

    func testUpdateFillsEveryMissingElevationAndKeepsExistingOnes() async throws {
        // Elevation is derived from the point so the test can check each value landed on the right point.
        StubUSGSProtocol.handler = { points in
            points.enumerated().map { index, point in (locationId: index, value: point[1] * 10) }
        }
        let feature = Feature(id: 1, type: .green, polygon: [
            Coordinate(latitude: 39.1, longitude: -105.0),
            Coordinate(latitude: 39.2, longitude: -105.0, elevation: 5),
            Coordinate(latitude: 39.3, longitude: -105.0),
        ])
        let course = makeCourse(features: [feature], centerline: [Coordinate(latitude: 39.4, longitude: -105.0)])

        let updated = try await ElevationUpdater.update(course, using: makeClient())

        XCTAssertFalse(updated.isMissingElevations)
        XCTAssertEqual(updated.location.coordinate.elevation, 390)
        XCTAssertEqual(updated.features[0].polygon.map(\.elevation), [391, 5, 393])
        XCTAssertEqual(updated.subCourses[0].holes[0].centerline[0].elevation, 394)
    }

    func testUpdateSplitsLargeCoursesIntoBatches() async throws {
        StubUSGSProtocol.handler = { points in
            points.enumerated().map { index, point in (locationId: index, value: point[1]) }
        }
        let count = USGSElevationClient.batchSize * 2 + 5
        let polygon = (0..<count).map { Coordinate(latitude: Double($0), longitude: -105.0) }
        let course = makeCourse(features: [Feature(id: 1, type: .fairway, polygon: polygon)], centerline: [])

        let updated = try await ElevationUpdater.update(course, using: makeClient())

        // +1 point for the course location.
        XCTAssertEqual(StubUSGSProtocol.requestCount, 3)
        XCTAssertEqual(updated.features[0].polygon.map(\.elevation), (0..<count).map { Double($0) })
    }

    func testUpdateThrowsWhenUSGSHasNoDataForAPoint() async {
        StubUSGSProtocol.handler = { points in
            points.indices.dropLast().map { (locationId: $0, value: 100) }
        }
        let feature = Feature(id: 1, type: .green, polygon: [Coordinate(latitude: 56.3, longitude: -2.8)])
        let course = makeCourse(features: [feature], centerline: [])

        do {
            _ = try await ElevationUpdater.update(course, using: makeClient())
            XCTFail("Expected noData error")
        } catch USGSElevationClient.ElevationError.noData(let missing, let total) {
            XCTAssertEqual(missing, 1)
            XCTAssertEqual(total, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateMakesNoRequestWhenNothingIsMissing() async throws {
        var course = makeCourse(features: [], centerline: [])
        course.location.coordinate.elevation = 1600

        let updated = try await ElevationUpdater.update(course, using: makeClient())

        XCTAssertEqual(updated, course)
        XCTAssertEqual(StubUSGSProtocol.requestCount, 0)
    }

    // MARK: - fillingMissingElevations

    func testFillingMissingElevationsSetsOnlyMissingOnes() {
        let feature = Feature(id: 1, type: .green, polygon: [
            Coordinate(latitude: 56.3, longitude: -2.8),
            Coordinate(latitude: 56.4, longitude: -2.8, elevation: 5),
        ])
        let course = makeCourse(features: [feature], centerline: [Coordinate(latitude: 56.5, longitude: -2.8)])

        let updated = ElevationUpdater.fillingMissingElevations(of: course, with: 0)

        XCTAssertFalse(updated.isMissingElevations)
        XCTAssertEqual(updated.location.coordinate.elevation, 0)
        XCTAssertEqual(updated.features[0].polygon.map(\.elevation), [0, 5])
        XCTAssertEqual(updated.subCourses[0].holes[0].centerline[0].elevation, 0)
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

    private func makeClient() -> USGSElevationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubUSGSProtocol.self]
        return USGSElevationClient(session: URLSession(configuration: configuration))
    }

    private func makeCourse(features: [Feature], centerline: [Coordinate]) -> Course {
        Course(
            name: "Test Course",
            location: CourseLocation(
                address: "", city: "Denver", state: "CO", country: "US",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            ),
            features: features,
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, centerline: centerline)])]
        )
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

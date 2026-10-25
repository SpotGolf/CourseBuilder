import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("OSM API client", .serialized)
struct OSMAPIClientTests {
    @Test func changesetIsClosedAfterFailedUpload() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            let path = request.url!.path()
            if path.hasSuffix("/changeset/create") { return (200, "42") }
            if path.hasSuffix("/changeset/42/upload") { return (500, "boom") }
            return (200, "")
        }
        let course = makeCourse()
        let changes = [OSMFeatureChange(action: .create, featureID: 1, type: .green, osmID: nil)]

        await #expect(throws: OSMAPIClient.APIError.http(statusCode: 500, message: "boom")) {
            _ = try await makeClient().publish(changes, course: course, baseline: OSMBaseline(), comment: "Fix")
        }
        #expect(StubOSMProtocol.requests.map { "\($0.httpMethod!) \($0.url!.path())" } == [
            "PUT /api/0.6/changeset/create",
            "POST /api/0.6/changeset/42/upload",
            "PUT /api/0.6/changeset/42/close",
        ])
    }

    @Test func uploadConflictIsReported() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            request.url!.path().hasSuffix("/upload") ? (409, "Version mismatch") : (200, "")
        }

        await #expect(throws: OSMAPIClient.APIError.conflict(message: "Version mismatch")) {
            _ = try await makeClient().upload(changesetID: 1, xml: "<osmChange/>")
        }
    }

    @Test func versionConflictSendsNothing() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            guard request.url!.path().hasSuffix("/way/10/full.json") else { return (200, "") }
            return (200, """
            {"elements": [
              {"type": "node", "id": 1, "version": 1, "lat": 40, "lon": -105},
              {"type": "way", "id": 10, "version": 8, "nodes": [1], "tags": {"golf": "green"}}
            ]}
            """)
        }
        let baseline = OSMBaseline(entries: ["w10": .init(osmID: "w10", version: 7, type: .green, points: [])])
        let changes = [OSMFeatureChange(action: .delete, featureID: nil, type: .green, osmID: "w10")]

        await #expect(throws: OSMAPIClient.APIError.conflicts(osmIDs: ["w10"])) {
            _ = try await makeClient().publish(changes, course: makeCourse(), baseline: baseline, comment: "Fix")
        }
        #expect(StubOSMProtocol.requests.count == 1)
    }

    @Test func publishSetsNewOSMIDs() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            let path = request.url!.path()
            if path.hasSuffix("/changeset/create") { return (200, "42") }
            if path.hasSuffix("/upload") {
                return (200, #"<diffResult><way old_id="-4" new_id="777" new_version="1"/></diffResult>"#)
            }
            return (200, "")
        }
        let changes = [OSMFeatureChange(action: .create, featureID: 1, type: .green, osmID: nil)]

        let result = try await makeClient().publish(changes, course: makeCourse(), baseline: OSMBaseline(), comment: "Fix")

        #expect(result.changesetID == 42)
        #expect(result.course.features[0].osmID == "w777")
        #expect(result.baseline.entries["w777"]?.version == 1)
        let auth = StubOSMProtocol.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer token")
    }

    @Test func relationWithTwoOuterWaysIsRejected() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            guard request.url!.path().hasSuffix("/relation/9.json") else { return (200, "") }
            return (200, """
            {"elements": [{"type": "relation", "id": 9, "version": 2, "tags": {"type": "multipolygon"},
              "members": [{"type": "way", "ref": 1, "role": "outer"}, {"type": "way", "ref": 2, "role": "outer"}]}]}
            """)
        }
        let changes = [OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "r9", pointsChanged: true)]

        await #expect(throws: OSMAPIClient.APIError.multipleOuterWays(osmID: "r9", count: 2)) {
            _ = try await makeClient().fetchElements(for: changes)
        }
    }

    @Test func relationPointEditFetchesOuterWay() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            let path = request.url!.path()
            if path.hasSuffix("/relation/9.json") {
                return (200, """
                {"elements": [{"type": "relation", "id": 9, "version": 2, "tags": {"type": "multipolygon"},
                  "members": [{"type": "way", "ref": 50, "role": "outer"}, {"type": "way", "ref": 51, "role": "inner"}]}]}
                """)
            }
            if path.hasSuffix("/way/50/full.json") {
                return (200, #"{"elements": [{"type": "node", "id": 1, "version": 1, "lat": 40, "lon": -105}, {"type": "way", "id": 50, "version": 4, "nodes": [1]}]}"#)
            }
            return (404, "")
        }
        let changes = [OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "r9", pointsChanged: true)]

        let fetched = try await makeClient().fetchElements(for: changes)

        #expect(fetched.outerWays == [9: 50])
        #expect(fetched.ways[50]?.way.version == 4)
    }

    @Test func relationDeleteFetchesEveryOuterWay() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            let path = request.url!.path()
            if path.hasSuffix("/relation/9.json") {
                return (200, """
                {"elements": [{"type": "relation", "id": 9, "version": 2, "tags": {"type": "multipolygon"},
                  "members": [{"type": "way", "ref": 50, "role": "outer"}, {"type": "way", "ref": 52, "role": "outer"}, {"type": "way", "ref": 51, "role": "inner"}]}]}
                """)
            }
            for id in [50, 52] where path.hasSuffix("/way/\(id)/full.json") {
                return (200, #"{"elements": [{"type": "node", "id": 1, "version": 1, "lat": 40, "lon": -105}, {"type": "way", "id": \#(id), "version": 4, "nodes": [1]}]}"#)
            }
            return (404, "")
        }
        let changes = [OSMFeatureChange(action: .delete, featureID: nil, type: .fairway, osmID: "r9")]

        let fetched = try await makeClient().fetchElements(for: changes)

        #expect(fetched.relations[9]?.version == 2)
        #expect(Set(fetched.ways.keys) == [50, 52])
        #expect(fetched.outerWays.isEmpty)
    }

    @Test func readsDetailsWithoutSignIn() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { request in
            switch (request.url!.path(), request.url!.query()) {
            case ("/api/0.6/relations.json", "relations=9"):
                return (200, """
                {"elements": [{"type": "relation", "id": 9, "version": 2, "tags": {"golf": "fairway", "type": "multipolygon"},
                  "members": [{"type": "way", "ref": 50, "role": "outer"}, {"type": "way", "ref": 51, "role": "inner"}]}]}
                """)
            case ("/api/0.6/ways.json", "ways=51,52"):
                return (200, """
                {"elements": [{"type": "way", "id": 51, "version": 3, "nodes": [], "tags": {"golf": "green"}},
                  {"type": "way", "id": 52, "version": 1, "nodes": []}]}
                """)
            default:
                return (404, "")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubOSMProtocol.self]

        let details = try await OSMAPIClient.details(of: ["r9", "w51", "w52"], session: URLSession(configuration: configuration))

        #expect(details == [
            "r9": OSMElementDetails(
                version: 2,
                tags: ["golf": "fairway", "type": "multipolygon"],
                members: [.init(type: "way", ref: 50, role: "outer"), .init(type: "way", ref: 51, role: "inner")]
            ),
            "w51": OSMElementDetails(version: 3, tags: ["golf": "green"]),
            "w52": OSMElementDetails(version: 1, tags: [:]),
        ])
        #expect(StubOSMProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func detailsAreReadInBatches() async throws {
        StubOSMProtocol.reset()
        StubOSMProtocol.handler = { _ in (200, #"{"elements": []}"#) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubOSMProtocol.self]
        let ids = (1...(OSMAPIClient.detailsBatchSize + 1)).map { "w\($0)" }

        _ = try await OSMAPIClient.details(of: ids, session: URLSession(configuration: configuration))

        #expect(StubOSMProtocol.requests.count == 2)
    }

    @Test func elementLinks() {
        #expect(OSMServer.elementURL(osmID: "w123")?.absoluteString == "https://www.openstreetmap.org/way/123")
        #expect(OSMServer.elementURL(osmID: "r9")?.absoluteString == "https://www.openstreetmap.org/relation/9")
        #expect(OSMServer.elementURL(osmID: "x1") == nil)
    }

    private func makeClient() -> OSMAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubOSMProtocol.self]
        return OSMAPIClient(token: "token", session: URLSession(configuration: configuration))
    }

    private func makeCourse() -> Course {
        Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
            features: [Feature(id: 1, type: .green, polygon: [
                Coordinate(lat: 40, lon: -105),
                Coordinate(lat: 40.0001, lon: -105),
                Coordinate(lat: 40.0001, lon: -105.0001),
            ])],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, features: [1])])]
        )
    }
}

/// Answers OSM API requests with `handler` and records them.
private final class StubOSMProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

import XCTest
@testable import CourseBuilder
import CourseDataSwift

final class USGSElevationClientTests: XCTestCase {
    func testBuildRequest() throws {
        let request = USGSElevationClient.buildRequest(for: [
            Coordinate(latitude: 39.639, longitude: -104.8846),
            Coordinate(latitude: 39.64, longitude: -104.8855),
        ])

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, USGSElevationClient.endpoint)

        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        var components = URLComponents()
        components.percentEncodedQuery = body
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["geometryType"], "esriGeometryMultipoint")
        XCTAssertEqual(items["returnFirstValueOnly"], "true")
        XCTAssertEqual(items["f"], "json")

        // Points are sent as [longitude, latitude].
        let geometry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(items["geometry"]).utf8)) as? [String: Any])
        let points = try XCTUnwrap(geometry["points"] as? [[Double]])
        XCTAssertEqual(points, [[-104.8846, 39.639], [-104.8855, 39.64]])
    }

    func testParseResponseRoundsToCentimeters() throws {
        let json = """
        {"samples":[
          {"locationId":0,"value":"1710.000976562","resolution":1},
          {"locationId":1,"value":"1710.066913086","resolution":1}
        ]}
        """
        let result = try USGSElevationClient.parseResponse(data: Data(json.utf8), count: 2)
        XCTAssertEqual(result, [1710.0, 1710.07])
    }

    func testParseResponseMatchesSamplesByLocationId() throws {
        // USGS leaves out points it has no data for, and may return samples in any order.
        let json = """
        {"samples":[
          {"locationId":2,"value":"12.5","resolution":1},
          {"locationId":0,"value":"10.25","resolution":1}
        ]}
        """
        let result = try USGSElevationClient.parseResponse(data: Data(json.utf8), count: 3)
        XCTAssertEqual(result, [10.25, nil, 12.5])
    }

    func testParseResponseIgnoresNoDataValues() throws {
        let json = """
        {"samples":[{"locationId":0,"value":"NoData"}]}
        """
        let result = try USGSElevationClient.parseResponse(data: Data(json.utf8), count: 1)
        XCTAssertEqual(result, [nil])
    }

    func testParseResponseThrowsRequestRejectedOnErrorBody() {
        // USGS answers HTTP 200 with this body when every point is outside its coverage.
        let json = """
        {"error":{"code":400,"extendedCode":-2147024809,"message":"Invalid or missing input parameters.","details":[]}}
        """
        XCTAssertThrowsError(try USGSElevationClient.parseResponse(data: Data(json.utf8), count: 1)) { error in
            guard case USGSElevationClient.ElevationError.requestRejected(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Invalid or missing input parameters.")
        }
    }

    func testParseResponseThrowsOnUnexpectedBody() {
        XCTAssertThrowsError(try USGSElevationClient.parseResponse(data: Data("{}".utf8), count: 1))
    }
}

import XCTest
@testable import CourseBuilder

final class OverpassAPIClientTests: XCTestCase {
    func testBuildQuery() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.78, west: -74.96, north: 39.80, east: -74.94)
        let query = OverpassAPIClient.buildQuery(bbox: bbox)
        XCTAssertTrue(query.contains("golf"))
        XCTAssertTrue(query.contains("39.78"))
        XCTAssertTrue(query.contains("-74.96"))
        XCTAssertTrue(query.contains("39.8"))
        XCTAssertTrue(query.contains("-74.94"))
    }

    func testParseFeaturesFromJSON() throws {
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 12345,
              "tags": { "golf": "fairway" },
              "geometry": [
                { "lat": 39.788, "lon": -74.958 },
                { "lat": 39.787, "lon": -74.957 },
                { "lat": 39.786, "lon": -74.956 }
              ]
            },
            {
              "type": "way",
              "id": 12346,
              "tags": { "golf": "green" },
              "geometry": [
                { "lat": 39.785, "lon": -74.955 },
                { "lat": 39.784, "lon": -74.954 }
              ]
            },
            {
              "type": "way",
              "id": 12347,
              "tags": { "golf": "hole", "ref": "1" },
              "geometry": [
                { "lat": 39.790, "lon": -74.960 },
                { "lat": 39.785, "lon": -74.955 }
              ]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)

        XCTAssertEqual(result.features.count, 2)
        XCTAssertEqual(result.features[0].type, .fairway)
        XCTAssertEqual(result.features[0].polygon.count, 3)
        XCTAssertEqual(result.features[1].type, .green)

        XCTAssertEqual(result.centerlines.count, 1)
        XCTAssertEqual(result.centerlines[0].holeNumber, 1)
        XCTAssertEqual(result.centerlines[0].coordinates.count, 2)
    }

    func testParseWaterHazardTypes() throws {
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 1,
              "tags": { "golf": "water_hazard" },
              "geometry": [{ "lat": 39.0, "lon": -105.0 }]
            },
            {
              "type": "way",
              "id": 2,
              "tags": { "golf": "lateral_water_hazard" },
              "geometry": [{ "lat": 39.0, "lon": -105.0 }]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)
        XCTAssertEqual(result.features.count, 2)
        XCTAssertTrue(result.features.allSatisfy { $0.type == .water })
    }

    func testBoundingBoxFromCoordinateWithPadding() {
        let center = Coordinate(latitude: 39.7879, longitude: -74.9580)
        let bbox = OverpassAPIClient.boundingBox(around: center, radiusMeters: 1000)
        XCTAssertLessThan(bbox.south, 39.7879)
        XCTAssertGreaterThan(bbox.north, 39.7879)
        XCTAssertLessThan(bbox.west, -74.9580)
        XCTAssertGreaterThan(bbox.east, -74.9580)
    }

    func testPadBoundingBox() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.78, west: -74.96, north: 39.80, east: -74.94)
        let padded = bbox.padded(by: 0.25)
        let latSpan = 39.80 - 39.78
        let lonSpan = -74.94 - (-74.96)
        XCTAssertEqual(padded.south, 39.78 - latSpan * 0.25, accuracy: 0.0001)
        XCTAssertEqual(padded.north, 39.80 + latSpan * 0.25, accuracy: 0.0001)
        XCTAssertEqual(padded.west, -74.96 - lonSpan * 0.25, accuracy: 0.0001)
        XCTAssertEqual(padded.east, -74.94 + lonSpan * 0.25, accuracy: 0.0001)
    }
}

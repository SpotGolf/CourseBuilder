import XCTest
@testable import CourseBuilder
import CourseDataSwift

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

    func testParseRelationGeometry() throws {
        let json = """
        {
          "elements": [
            {
              "type": "relation",
              "id": 53408,
              "tags": { "leisure": "golf_course", "type": "multipolygon" },
              "members": [
                {
                  "type": "way",
                  "ref": 12345,
                  "role": "outer",
                  "geometry": [
                    { "lat": 39.41, "lon": -74.37 },
                    { "lat": 39.42, "lon": -74.37 },
                    { "lat": 39.42, "lon": -74.36 },
                    { "lat": 39.41, "lon": -74.36 },
                    { "lat": 39.41, "lon": -74.37 }
                  ]
                },
                {
                  "type": "way",
                  "ref": 12346,
                  "role": "inner",
                  "geometry": [
                    { "lat": 39.415, "lon": -74.365 },
                    { "lat": 39.416, "lon": -74.365 }
                  ]
                }
              ]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)
        // Course boundary from outer role only
        XCTAssertNotNil(result.courseBoundary)
        XCTAssertEqual(result.courseBoundary?.count, 5)
    }

    func testClubhouseTaggedAsGolfCourseIsNotBoundary() throws {
        // Bear Dance: the clubhouse building carries leisure=golf_course by mistake.
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 237236029,
              "tags": { "building": "yes", "golf": "clubhouse", "leisure": "golf_course", "name": "Golf Club at Bear Dance" },
              "geometry": [
                { "lat": 39.2660, "lon": -104.9107 },
                { "lat": 39.2662, "lon": -104.9107 },
                { "lat": 39.2662, "lon": -104.9104 },
                { "lat": 39.2660, "lon": -104.9104 },
                { "lat": 39.2660, "lon": -104.9107 }
              ]
            }
          ]
        }
        """
        let result = try OverpassAPIClient.parseResponse(data: json.data(using: .utf8)!)
        XCTAssertNil(result.courseBoundary)
        XCTAssertTrue(result.features.isEmpty)
    }

    func testIsCourseBoundary() {
        XCTAssertTrue(OverpassAPIClient.isCourseBoundary(tags: ["leisure": "golf_course"]))
        XCTAssertTrue(OverpassAPIClient.isCourseBoundary(tags: ["leisure": "golf_course", "name": "Broadlands"]))
        XCTAssertFalse(OverpassAPIClient.isCourseBoundary(tags: ["leisure": "golf_course", "golf": "clubhouse"]))
        XCTAssertFalse(OverpassAPIClient.isCourseBoundary(tags: ["leisure": "golf_course", "building": "yes"]))
        XCTAssertFalse(OverpassAPIClient.isCourseBoundary(tags: ["golf": "fairway"]))
    }

    func testBoundaryBoundingBoxRejectsSmallOrMissingBoundary() {
        XCTAssertNil(OverpassAPIClient.boundaryBoundingBox(for: nil))
        XCTAssertNil(OverpassAPIClient.boundaryBoundingBox(for: [
            Coordinate(latitude: 39.0, longitude: -105.0),
            Coordinate(latitude: 39.01, longitude: -105.0),
        ]))
        // A building-sized polygon (~44 m x 31 m) is not a course outline
        let building = [
            Coordinate(latitude: 39.2660, longitude: -104.9107),
            Coordinate(latitude: 39.2664, longitude: -104.9107),
            Coordinate(latitude: 39.2664, longitude: -104.9103),
            Coordinate(latitude: 39.2660, longitude: -104.9103),
        ]
        XCTAssertNil(OverpassAPIClient.boundaryBoundingBox(for: building))
    }

    func testBoundaryBoundingBoxUsesRealOutline() throws {
        // ~1.1 km x 1.5 km outline
        let outline = [
            Coordinate(latitude: 39.00, longitude: -105.00),
            Coordinate(latitude: 39.01, longitude: -105.00),
            Coordinate(latitude: 39.01, longitude: -104.98),
            Coordinate(latitude: 39.00, longitude: -104.98),
        ]
        let bbox = try XCTUnwrap(OverpassAPIClient.boundaryBoundingBox(for: outline))
        XCTAssertEqual(bbox.south, 39.00 - 0.01 * 0.25, accuracy: 0.0001)
        XCTAssertEqual(bbox.north, 39.01 + 0.01 * 0.25, accuracy: 0.0001)
        XCTAssertEqual(bbox.west, -105.00 - 0.02 * 0.25, accuracy: 0.0001)
        XCTAssertEqual(bbox.east, -104.98 + 0.02 * 0.25, accuracy: 0.0001)
    }

    func testBoundingBoxSpanMeters() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.0, west: -105.0, north: 39.01, east: -105.0)
        XCTAssertEqual(bbox.spanMeters, 1113.2, accuracy: 1)
    }

    func testParseNaturalWater() throws {
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 99,
              "tags": { "natural": "water" },
              "geometry": [
                { "lat": 39.0, "lon": -105.0 },
                { "lat": 39.001, "lon": -105.001 },
                { "lat": 39.002, "lon": -105.0 }
              ]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)
        XCTAssertEqual(result.features.count, 1)
        XCTAssertEqual(result.features[0].type, .water)
    }

    func testParseRelationFairway() throws {
        let json = """
        {
          "elements": [
            {
              "type": "relation",
              "id": 100,
              "tags": { "golf": "fairway", "type": "multipolygon" },
              "members": [
                {
                  "type": "way",
                  "ref": 200,
                  "role": "outer",
                  "geometry": [
                    { "lat": 39.0, "lon": -105.0 },
                    { "lat": 39.001, "lon": -105.001 },
                    { "lat": 39.002, "lon": -105.0 }
                  ]
                }
              ]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)
        XCTAssertEqual(result.features.count, 1)
        XCTAssertEqual(result.features[0].type, .fairway)
        XCTAssertEqual(result.features[0].polygon.count, 3)
    }

    func testParseElementsWithNumericTagValues() throws {
        // OSM elements can have numeric tag values (e.g. "layer": 1) which
        // would cause a [String: String] cast to fail. Verify we handle them.
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 1,
              "tags": { "golf": "tee", "layer": 1, "ele": 150.5 },
              "geometry": [
                { "lat": 39.0, "lon": -105.0 },
                { "lat": 39.001, "lon": -105.0 },
                { "lat": 39.001, "lon": -105.001 },
                { "lat": 39.0, "lon": -105.001 }
              ]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)
        XCTAssertEqual(result.features.count, 1)
        XCTAssertEqual(result.features[0].type, .tee)
    }

    func testParseBroadlandsJSON() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "broadlands", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let result = try OverpassAPIClient.parseResponse(data: data)

        // Broadlands has: 3 fairway ways + 11 fairway relations, 15 greens, 45 tees,
        // 46 bunkers, 11 water_hazard ways, 14 hole centerlines
        // Total features: 3+11+15+45+46+11 = 131
        XCTAssertEqual(result.features.count, 131, "Expected 131 features (fairways + greens + tees + bunkers + water)")

        let fairways = result.features.filter { $0.type == .fairway }
        let greens = result.features.filter { $0.type == .green }
        let tees = result.features.filter { $0.type == .tee }
        let bunkers = result.features.filter { $0.type == .bunker }
        let water = result.features.filter { $0.type == .water }

        XCTAssertEqual(fairways.count, 14, "Expected 14 fairways (3 ways + 11 relations)")
        XCTAssertEqual(greens.count, 15, "Expected 15 greens")
        XCTAssertEqual(tees.count, 45, "Expected 45 tees")
        XCTAssertEqual(bunkers.count, 46, "Expected 46 bunkers")
        XCTAssertEqual(water.count, 11, "Expected 11 water hazards")

        XCTAssertEqual(result.centerlines.count, 14, "Expected 14 hole centerlines")
        XCTAssertNotNil(result.courseBoundary, "Expected course boundary")

        // Verify all features have non-empty polygons
        for feature in result.features {
            XCTAssertGreaterThan(feature.polygon.count, 0, "Feature \(feature.type) should have vertices")
        }
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

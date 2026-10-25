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
        XCTAssertTrue(query.contains(#"way["natural"="sand"]"#))
        XCTAssertTrue(query.contains(#"relation["natural"="sand"]"#))
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
        XCTAssertEqual(result.features.map(\.osmID), ["w12345", "w12346"])

        XCTAssertEqual(result.centerlines.count, 1)
        XCTAssertEqual(result.centerlines[0].holeNumber, 1)
        XCTAssertEqual(result.centerlines[0].coordinates.count, 2)
        XCTAssertEqual(result.centerlines[0].osmID, "w12347")
    }

    func testParseReadsVersionsFromMetadata() throws {
        let json = """
        {
          "elements": [
            {
              "type": "way", "id": 10, "version": 4,
              "tags": { "golf": "green" },
              "geometry": [{ "lat": 39.785, "lon": -74.955 }, { "lat": 39.784, "lon": -74.954 }]
            },
            {
              "type": "way", "id": 11, "version": 7,
              "tags": { "golf": "hole", "ref": "1" },
              "geometry": [{ "lat": 39.790, "lon": -74.960 }, { "lat": 39.785, "lon": -74.955 }]
            },
            {
              "type": "way", "id": 12,
              "tags": { "golf": "tee" },
              "geometry": [{ "lat": 39.790, "lon": -74.960 }, { "lat": 39.791, "lon": -74.961 }]
            }
          ]
        }
        """
        let result = try OverpassAPIClient.parseResponse(data: Data(json.utf8))

        XCTAssertEqual(result.features.map(\.version), [4, nil])
        XCTAssertEqual(result.centerlines[0].version, 7)
        XCTAssertTrue(OverpassAPIClient.buildQuery(bbox: .init(south: 0, west: 0, north: 1, east: 1)).contains("out geom meta;"))
    }

    func testOSMIDUsesElementTypePrefix() {
        XCTAssertEqual(OverpassAPIClient.osmID(of: ["type": "node", "id": 1]), "n1")
        XCTAssertEqual(OverpassAPIClient.osmID(of: ["type": "way", "id": 2]), "w2")
        XCTAssertEqual(OverpassAPIClient.osmID(of: ["type": "relation", "id": 3]), "r3")
        XCTAssertNil(OverpassAPIClient.osmID(of: ["type": "area", "id": 4]))
        XCTAssertNil(OverpassAPIClient.osmID(of: ["type": "way"]))
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
        let center = Coordinate(lat: 39.7879, lon: -74.9580)
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

    func testBuildQueryForWayIDs() {
        XCTAssertEqual(OverpassAPIClient.buildQuery(wayIDs: [907057602, 5]), """
        [out:json][timeout:30];
        way(id:907057602,5);
        out geom meta;
        """)
    }

    func testMissingInnerWaysAreFoundAndAdded() {
        // Bear Dance hole 14: the fairway relation reaches into the search area, its green does not.
        let fairway = OverpassAPIClient.ParsedFeature(type: .fairway, polygon: [], osmID: "r19767874", members: [
            OSMRelation.Member(type: "way", ref: 1118168789, role: "outer"),
            OSMRelation.Member(type: "way", ref: 907057602, role: "inner"),
            OSMRelation.Member(type: "way", ref: 10, role: "inner"),
        ])
        let present = OverpassAPIClient.ParsedFeature(type: .green, polygon: [], osmID: "w10")
        let result = OverpassAPIClient.ParsedResult(features: [fairway, present], centerlines: [], courseBoundary: nil)

        XCTAssertEqual(result.missingInnerWayIDs, [907057602])

        let green = OverpassAPIClient.ParsedFeature(type: .green, polygon: [], osmID: "w907057602")
        let extra = OverpassAPIClient.ParsedResult(features: [green, present], centerlines: [], courseBoundary: nil)
        let combined = result.adding(extra)

        XCTAssertEqual(combined.features.compactMap(\.osmID), ["r19767874", "w10", "w907057602"])
        XCTAssertTrue(combined.missingInnerWayIDs.isEmpty)
    }

    func testSearchAreaGrowsToHoldFeaturesPastItsEdge() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.257, west: -104.922, north: 39.275, east: -104.899)
        // A fairway reaching 0.001° west of the area, and a lake far to the east.
        let fairway = OverpassAPIClient.ParsedFeature(type: .fairway, polygon: [
            Coordinate(lat: 39.265, lon: -104.923), Coordinate(lat: 39.266, lon: -104.915),
        ])
        let lake = OverpassAPIClient.ParsedFeature(type: .water, polygon: [Coordinate(lat: 39.265, lon: -104.85)])
        let result = OverpassAPIClient.ParsedResult(features: [fairway, lake], centerlines: [], courseBoundary: nil)

        let grown = OverpassAPIClient.grownBoundingBox(bbox, for: result, marginMeters: 100)

        let lonMargin = 100 / (111_320.0 * cos(39.2655 * .pi / 180))
        XCTAssertEqual(grown?.west ?? 0, -104.923 - lonMargin, accuracy: 1e-9)
        XCTAssertEqual(grown?.east, bbox.east)
        XCTAssertEqual(grown?.south, bbox.south)
        XCTAssertEqual(grown?.north, bbox.north)
    }

    func testSearchAreaDoesNotGrowWhenFeaturesAreInside() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.257, west: -104.922, north: 39.275, east: -104.899)
        let green = OverpassAPIClient.ParsedFeature(type: .green, polygon: [Coordinate(lat: 39.266, lon: -104.91)])
        let result = OverpassAPIClient.ParsedResult(features: [green], centerlines: [], courseBoundary: nil)

        XCTAssertNil(OverpassAPIClient.grownBoundingBox(bbox, for: result))
    }

    func testSearchAreaDoesNotGrowBySmallAmounts() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.257, west: -104.922, north: 39.275, east: -104.899)
        // 10 m inside the west edge, so the 150 m margin grows it by about 140 m, but a 200 m minimum is not met.
        let tee = OverpassAPIClient.ParsedFeature(type: .tee, polygon: [Coordinate(lat: 39.266, lon: -104.922 + 10 / (111_320.0 * cos(39.266 * .pi / 180)))])
        let result = OverpassAPIClient.ParsedResult(features: [tee], centerlines: [], courseBoundary: nil)

        XCTAssertNil(OverpassAPIClient.grownBoundingBox(bbox, for: result, minimumGrowthMeters: 200))
        XCTAssertNotNil(OverpassAPIClient.grownBoundingBox(bbox, for: result))
    }

    func testSearchAreaDoesNotGrowPastLimit() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.257, west: -104.922, north: 39.275, east: -104.899)
        let farTee = OverpassAPIClient.ParsedFeature(type: .tee, polygon: [Coordinate(lat: 39.266, lon: -105.0)])
        let result = OverpassAPIClient.ParsedResult(features: [farTee], centerlines: [], courseBoundary: nil)

        XCTAssertNil(OverpassAPIClient.grownBoundingBox(bbox, for: result))
    }

    func testMembersOfRelation() {
        let relation: [String: Any] = [
            "type": "relation",
            "id": 14322211,
            "members": [
                ["type": "way", "ref": 742745098, "role": "outer"],
                ["type": "way", "ref": 742745097, "role": "inner"],
                ["type": "node", "ref": 5, "role": "inner"],
            ],
        ]
        XCTAssertEqual(OverpassAPIClient.members(of: relation), [
            OSMRelation.Member(type: "way", ref: 742745098, role: "outer"),
            OSMRelation.Member(type: "way", ref: 742745097, role: "inner"),
            OSMRelation.Member(type: "node", ref: 5, role: "inner"),
        ])
        XCTAssertNil(OverpassAPIClient.members(of: ["type": "way", "id": 1]))
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
            Coordinate(lat: 39.0, lon: -105.0),
            Coordinate(lat: 39.01, lon: -105.0),
        ]))
        // A building-sized polygon (~44 m x 31 m) is not a course outline
        let building = [
            Coordinate(lat: 39.2660, lon: -104.9107),
            Coordinate(lat: 39.2664, lon: -104.9107),
            Coordinate(lat: 39.2664, lon: -104.9103),
            Coordinate(lat: 39.2660, lon: -104.9103),
        ]
        XCTAssertNil(OverpassAPIClient.boundaryBoundingBox(for: building))
    }

    func testBoundaryBoundingBoxUsesRealOutline() throws {
        // ~1.1 km x 1.5 km outline
        let outline = [
            Coordinate(lat: 39.00, lon: -105.00),
            Coordinate(lat: 39.01, lon: -105.00),
            Coordinate(lat: 39.01, lon: -104.98),
            Coordinate(lat: 39.00, lon: -104.98),
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

    func testParseSandAsBunker() throws {
        // Bear Dance hole 16: a bunker tagged only natural=sand.
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 1373233826,
              "tags": { "natural": "sand" },
              "geometry": [
                { "lat": 39.26009, "lon": -104.91688 },
                { "lat": 39.26022, "lon": -104.91688 },
                { "lat": 39.26022, "lon": -104.91674 }
              ]
            }
          ]
        }
        """
        let result = try OverpassAPIClient.parseResponse(data: json.data(using: .utf8)!)
        XCTAssertEqual(result.features.count, 1)
        XCTAssertEqual(result.features[0].type, .bunker)
        XCTAssertEqual(result.features[0].tags, ["natural": "sand"])
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

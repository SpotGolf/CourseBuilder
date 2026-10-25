import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

/// A coordinate `north` and `east` meters from a base point.
private func point(north: Double, east: Double = 0) -> Coordinate {
    let baseLat = 40.0
    return Coordinate(
        lat: baseLat + north / 111_320.0,
        lon: -105.0 + east / (111_320.0 * cos(baseLat * .pi / 180))
    )
}

private func makeCourse(features: [Feature]) -> Course {
    Course(
        name: "Test",
        location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
        features: features,
        subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])]
    )
}

/// The clubhouse tags from Bear Dance (`w237236029`).
private let clubhouseTags = [
    "access": "customers", "addr:city": "Larkspur", "addr:housenumber": "6630", "addr:postcode": "80118",
    "addr:state": "CO", "addr:street": "Bear Dance Drive", "building": "yes", "building:levels": "2",
    "check_date": "2026-08-15", "golf": "clubhouse", "internet_access": "wlan", "internet_access:fee": "customers",
    "leisure": "golf_course", "name": "Golf Club at Bear Dance", "opening_hours": "Mo-Su 11:00-20:30",
    "operator": "Heritage Golf Group", "payment:cash": "yes", "payment:credit_cards": "yes", "payment:debit_cards": "yes",
    "phone": "+1-303-681-4653", "website": "https://www.beardancegolf.com/", "wheelchair": "limited",
]

private let clubhouse = MisplacedCourseElement(osmID: "w237236029", version: 4, tags: clubhouseTags, center: point(north: 0))
private let courseNode = MisplacedCourseElement(osmID: "n55", version: 2, tags: ["leisure": "golf_course", "name": "Test Golf"], center: point(north: 0))

private func parse(_ json: String) throws -> OverpassAPIClient.ParsedResult {
    try OverpassAPIClient.parseResponse(data: Data(json.utf8))
}

@Suite("Course outline")
struct CourseOutlineTests {
    // MARK: - Parser

    @Test func nodeIsMisplaced() throws {
        let result = try parse("""
        {"elements": [{"type": "node", "id": 55, "version": 2, "lat": 40.0, "lon": -105.0, "tags": {"leisure": "golf_course", "name": "Test Golf"}}]}
        """)

        #expect(result.misplacedCourseElements.map(\.osmID) == ["n55"])
        #expect(result.misplacedCourseElements.first?.version == 2)
        #expect(result.misplacedCourseElements.first?.tags["name"] == "Test Golf")
    }

    @Test func clubhouseWayIsMisplaced() throws {
        let result = try parse("""
        {"elements": [{"type": "way", "id": 237236029, "version": 4,
          "tags": {"leisure": "golf_course", "golf": "clubhouse", "building": "yes"},
          "geometry": [{"lat": 40.0, "lon": -105.0}, {"lat": 40.0003, "lon": -105.0}, {"lat": 40.0003, "lon": -105.0004}, {"lat": 40.0, "lon": -105.0}]}]}
        """)

        #expect(result.misplacedCourseElements.map(\.osmID) == ["w237236029"])
    }

    @Test func usableOutlineMeansNothingIsMisplaced() throws {
        let result = try parse("""
        {"elements": [
          {"type": "node", "id": 55, "lat": 40.0, "lon": -105.0, "tags": {"leisure": "golf_course"}},
          {"type": "way", "id": 9, "tags": {"leisure": "golf_course"},
           "geometry": [{"lat": 40.0, "lon": -105.0}, {"lat": 40.01, "lon": -105.0}, {"lat": 40.01, "lon": -105.01}, {"lat": 40.0, "lon": -105.0}]}
        ]}
        """)

        #expect(result.misplacedCourseElements.isEmpty)
        #expect(result.courseBoundary != nil)
    }

    @Test func nearestElementIsPicked() {
        let far = MisplacedCourseElement(osmID: "n1", tags: [:], center: point(north: 500))
        let near = MisplacedCourseElement(osmID: "n2", tags: [:], center: point(north: 20))
        #expect(CourseOutline.nearest([far, near], to: point(north: 0))?.osmID == "n2")
    }

    // MARK: - Hull

    @Test func hullSurroundsFeaturesWithMargin() {
        let green = Feature(id: 1, type: .green, polygon: [point(north: 0), point(north: 0, east: 20), point(north: 20, east: 20), point(north: 20)])
        let tee = Feature(id: 2, type: .tee, polygon: [point(north: 300, east: 5), point(north: 300, east: 15), point(north: 310, east: 10)])
        let lake = Feature(id: 3, type: .water, polygon: [point(north: 0, east: 1000), point(north: 0, east: 2000), point(north: 1000, east: 2000)])
        let course = makeCourse(features: [green, tee, lake])

        let hull = CourseOutline.hull(for: course)

        let points = Array(green.polygon) + Array(tee.polygon)
        #expect(points.allSatisfy { PolygonGeometry.contains($0, in: hull) })
        // The 8-sided circles keep every point at least 30 m × cos(22.5°) inside the outline.
        let metersPerLon = 111_320 * cos(40.0 * .pi / 180)
        func meters(_ c: Coordinate) -> Coordinate { Coordinate(lat: c.lat * 111_320, lon: c.lon * metersPerLon) }
        let hullMeters = hull.map(meters)
        for point in points.map(meters) {
            let nearest = zip(hullMeters, hullMeters.dropFirst() + [hullMeters[0]]).map { a, b in
                PolygonGeometry.squaredDistanceToSegment(point, segStart: a, segEnd: b).squareRoot()
            }.min()!
            #expect(nearest >= 27)
        }
        // The lake is left out.
        #expect(!hull.contains { $0.lon > point(north: 0, east: 100).lon })
        #expect(isConvex(hull))
    }

    @Test func hullOfEmptyCourseIsEmpty() {
        #expect(CourseOutline.hull(for: makeCourse(features: [])).isEmpty)
    }

    // MARK: - Tags

    @Test func clubhouseTagsStartChecked() {
        let checked = clubhouseTags.keys.filter { CourseOutline.movesByDefault(key: $0, from: clubhouse) }.sorted()
        #expect(checked == [
            "access", "leisure", "name", "opening_hours", "operator",
            "payment:cash", "payment:credit_cards", "payment:debit_cards", "phone", "website",
        ])
        #expect(CourseOutline.mustMove(key: "leisure", from: clubhouse))
        #expect(!CourseOutline.mustMove(key: "name", from: clubhouse))
        // Bear Dance's clubhouse already has golf=clubhouse.
        #expect(!CourseOutline.offersClubhouseTag(for: clubhouse))
    }

    @Test func buildingWithoutClubhouseTagGetsOffer() {
        let building = MisplacedCourseElement(osmID: "w1", tags: ["leisure": "golf_course", "building": "yes"], center: point(north: 0))
        #expect(CourseOutline.offersClubhouseTag(for: building))
        #expect(CourseOutline.clubhouseTagByDefault(for: building))
    }

    @Test func nodeMovesEveryTag() {
        #expect(courseNode.tags.keys.allSatisfy { CourseOutline.movesByDefault(key: $0, from: courseNode) && CourseOutline.mustMove(key: $0, from: courseNode) })
        #expect(!CourseOutline.offersClubhouseTag(for: courseNode))
    }

    // MARK: - Publish

    private let outlinePoints = [point(north: -50, east: -50), point(north: -50, east: 50), point(north: 50, east: 50), point(north: 50, east: -50)]

    @Test func pendingOutlineIsAChange() {
        let course = makeCourse(features: [])
        var baseline = OSMBaseline(course: course)
        baseline.misplacedCourseElement = clubhouse
        #expect(OSMChangeDetector.changes(in: course, from: baseline).isEmpty)

        let outline = PendingCourseOutline(coordinates: outlinePoints, tags: ["leisure": "golf_course"], tagsOldElementClubhouse: false)
        baseline.pendingCourseOutline = outline

        #expect(OSMChangeDetector.changes(in: course, from: baseline) == [
            OSMFeatureChange(action: .courseOutline, featureID: nil, type: .fairway, osmID: "w237236029", courseOutline: outline),
        ])
    }

    @Test func nodeUploadCreatesOutlineAndDeletesNode() {
        let outline = PendingCourseOutline(coordinates: outlinePoints, tags: courseNode.tags, tagsOldElementClubhouse: false)
        let fetched = OSMFetchedElements(nodes: [55: OSMNode(id: 55, version: 2, lat: 40, lon: -105, tags: courseNode.tags)])
        let changes = [OSMFeatureChange(action: .courseOutline, featureID: nil, type: .fairway, osmID: "n55", courseOutline: outline)]

        let upload = OSMChangeBuilder.upload(for: changes, course: makeCourse(features: []), fetched: fetched, changesetID: 7)

        #expect(upload.xml.contains("<way id=\"-5\" changeset=\"7\">\n    <nd ref=\"-1\"/>\n    <nd ref=\"-2\"/>\n    <nd ref=\"-3\"/>\n    <nd ref=\"-4\"/>\n    <nd ref=\"-1\"/>\n    <tag k=\"leisure\" v=\"golf_course\"/>\n    <tag k=\"name\" v=\"Test Golf\"/>\n  </way>"))
        #expect(upload.xml.contains("<delete if-unused=\"true\">\n  <node id=\"55\" version=\"2\" changeset=\"7\""))
        #expect(!upload.xml.contains("<modify>"))
    }

    @Test func wayUploadMovesTagsAndAddsClubhouse() {
        let tags = ["leisure": "golf_course", "name": "Test Golf", "building": "yes"]
        let element = MisplacedCourseElement(osmID: "w8", version: 3, tags: tags, center: point(north: 0))
        let outline = PendingCourseOutline(coordinates: outlinePoints, tags: ["leisure": "golf_course", "name": "Test Golf"], tagsOldElementClubhouse: true)
        let fetched = OSMFetchedElements(ways: [8: OSMWayFull(way: OSMWay(id: 8, version: 3, nodes: [1, 2, 3, 1], tags: tags), nodes: [:])])
        let changes = [OSMFeatureChange(action: .courseOutline, featureID: nil, type: .fairway, osmID: element.osmID, courseOutline: outline)]

        let upload = OSMChangeBuilder.upload(for: changes, course: makeCourse(features: []), fetched: fetched, changesetID: 7)

        #expect(upload.xml.contains("<way id=\"8\" version=\"3\" changeset=\"7\">\n    <nd ref=\"1\"/>\n    <nd ref=\"2\"/>\n    <nd ref=\"3\"/>\n    <nd ref=\"1\"/>\n    <tag k=\"building\" v=\"yes\"/>\n    <tag k=\"golf\" v=\"clubhouse\"/>\n  </way>"))
        #expect(upload.sent["w-5"]?.tags == ["leisure": "golf_course", "name": "Test Golf"])
        #expect(!upload.xml.contains("<delete"))
    }

    @Test func changedElementIsAConflict() {
        var baseline = OSMBaseline()
        baseline.misplacedCourseElement = clubhouse
        let changes = [OSMFeatureChange(action: .courseOutline, featureID: nil, type: .fairway, osmID: clubhouse.osmID)]
        let way = OSMWay(id: 237236029, version: 5, nodes: [], tags: clubhouseTags)
        let fetched = OSMFetchedElements(ways: [237236029: OSMWayFull(way: way, nodes: [:])])

        #expect(OSMChangeBuilder.conflicts(in: changes, baseline: baseline, fetched: fetched) == [clubhouse.osmID])
    }

    @Test func applyRemovesPendingOutline() {
        var course = makeCourse(features: [])
        var baseline = OSMBaseline()
        baseline.misplacedCourseElement = clubhouse
        baseline.pendingCourseOutline = PendingCourseOutline(coordinates: outlinePoints, tags: ["leisure": "golf_course"], tagsOldElementClubhouse: false)
        let changes = [OSMFeatureChange(action: .courseOutline, featureID: nil, type: .fairway, osmID: clubhouse.osmID)]
        let upload = OSMChangeBuilder.Upload(xml: "", createdWays: [:])
        let diff = [OSMDiffEntry(type: "way", oldID: -5, newID: 900, newVersion: 1), OSMDiffEntry(type: "way", oldID: 237236029, newID: 237236029, newVersion: 5)]

        let result = OSMChangeBuilder.apply(diff, upload: upload, changes: changes, course: &course, baseline: baseline)

        #expect(result.pendingCourseOutline == nil)
        #expect(result.misplacedCourseElement == nil)
    }

    @Test func oldBaselineLoadsWithoutOutlineFields() throws {
        let baseline = try JSONDecoder().decode(OSMBaseline.self, from: Data(#"{"entries": {}}"#.utf8))
        #expect(baseline.misplacedCourseElement == nil)
        #expect(baseline.pendingCourseOutline == nil)
        #expect(!baseline.checkedCourseElement)
    }

    @Test func baselineKeepsOutlineFields() throws {
        var baseline = OSMBaseline()
        baseline.misplacedCourseElement = clubhouse
        baseline.pendingCourseOutline = PendingCourseOutline(coordinates: outlinePoints, tags: ["leisure": "golf_course"], tagsOldElementClubhouse: true)
        baseline.checkedCourseElement = true

        let decoded = try JSONDecoder().decode(OSMBaseline.self, from: JSONEncoder().encode(baseline))

        #expect(decoded == baseline)
    }

    /// Whether every turn of the closed outline goes the same way.
    private func isConvex(_ points: [Coordinate]) -> Bool {
        let turns = points.indices.map { i in
            let a = points[i], b = points[(i + 1) % points.count], c = points[(i + 2) % points.count]
            return (b.lon - a.lon) * (c.lat - b.lat) - (b.lat - a.lat) * (c.lon - b.lon)
        }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }
}

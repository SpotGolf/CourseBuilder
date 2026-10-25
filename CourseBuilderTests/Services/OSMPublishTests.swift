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

/// A 10 m square, as an open list of four points.
private func square(north: Double = 0) -> [Coordinate] {
    [point(north: north), point(north: north, east: 10), point(north: north + 10, east: 10), point(north: north + 10)]
}

private func makeCourse(features: [Feature], holes: [Hole] = [Hole(number: 1, par: 4)]) -> Course {
    Course(
        name: "Test",
        location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
        features: features,
        subCourses: [SubCourse(name: "Front", holes: holes)]
    )
}

@Suite("OSM change detection")
struct OSMChangeDetectorTests {
    @Test func noChanges() {
        let course = makeCourse(features: [Feature(id: 1, type: .bunker, polygon: CoordinatePath(square()), osmID: "w1")])
        #expect(OSMChangeDetector.changes(in: course, from: OSMBaseline(course: course)).isEmpty)
    }

    @Test func typeChange() {
        var course = makeCourse(features: [Feature(id: 1, type: .bunker, polygon: CoordinatePath(square()), osmID: "w1")])
        let baseline = OSMBaseline(course: course)
        course.features[0] = Feature(id: 1, type: .water, polygon: course.features[0].polygon, osmID: "w1")

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes == [OSMFeatureChange(action: .modify, featureID: 1, type: .water, osmID: "w1", oldType: .bunker)])
    }

    @Test func movedPoint() {
        var course = makeCourse(features: [Feature(id: 1, type: .green, polygon: CoordinatePath(square()), osmID: "w1")])
        let baseline = OSMBaseline(course: course)
        course.features[0].polygon.replace(at: 0, with: point(north: -2))

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes == [OSMFeatureChange(action: .modify, featureID: 1, type: .green, osmID: "w1", pointsChanged: true)])
    }

    @Test func pointWithinHalfMeterIsNotAChange() {
        var course = makeCourse(features: [Feature(id: 1, type: .green, polygon: CoordinatePath(square()), osmID: "w1")])
        let baseline = OSMBaseline(course: course)
        course.features[0].polygon.replace(at: 0, with: point(north: 0.3))

        #expect(OSMChangeDetector.changes(in: course, from: baseline).isEmpty)
    }

    @Test func newAndDeleted() {
        let baseline = OSMBaseline(course: makeCourse(features: [Feature(id: 1, type: .tee, polygon: CoordinatePath(square()), osmID: "w1")]))
        let course = makeCourse(features: [Feature(id: 2, type: .tee, polygon: CoordinatePath(square()))])

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes == [
            OSMFeatureChange(action: .create, featureID: 2, type: .tee, osmID: nil),
            OSMFeatureChange(action: .delete, featureID: nil, type: .tee, osmID: "w1"),
        ])
    }

    @Test func relationPointsAndDeletesAreSent() {
        var course = makeCourse(features: [
            Feature(id: 1, type: .fairway, polygon: CoordinatePath(square()), osmID: "r1"),
            Feature(id: 2, type: .fairway, polygon: CoordinatePath(square()), osmID: "r2"),
        ])
        let baseline = OSMBaseline(course: course)
        course.features[0].polygon.replace(at: 0, with: point(north: -5))
        course.features.remove(at: 1)

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes == [
            OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "r1", pointsChanged: true),
            OSMFeatureChange(action: .delete, featureID: nil, type: .fairway, osmID: "r2"),
        ])
    }

    @Test func pendingMultipolygonIsAChange() {
        let course = makeCourse(features: [
            Feature(id: 1, type: .fairway, polygon: CoordinatePath(square()), osmID: "w1"),
            Feature(id: 2, type: .green, polygon: CoordinatePath(square()), osmID: "w2"),
        ])
        var baseline = OSMBaseline(course: course)
        baseline.pendingMultipolygons = [PendingMultipolygon(fairwayOSMID: "w1", innerOSMIDs: ["w2", "w9"])]

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        // w9 is no longer in the course, so it is left out.
        #expect(changes == [OSMFeatureChange(action: .multipolygon, featureID: 1, type: .fairway, osmID: "w1", innerOSMIDs: ["w2"])])
    }

    @Test func pendingMultipolygonWithoutGreensIsDropped() {
        let course = makeCourse(features: [Feature(id: 1, type: .fairway, polygon: CoordinatePath(square()), osmID: "w1")])
        var baseline = OSMBaseline(course: course)
        baseline.pendingMultipolygons = [PendingMultipolygon(fairwayOSMID: "w1", innerOSMIDs: ["w2"])]

        #expect(OSMChangeDetector.changes(in: course, from: baseline).isEmpty)
    }

    @Test func sandBunkerGetsGolfTag() {
        let course = makeCourse(features: [
            Feature(id: 1, type: .bunker, polygon: CoordinatePath(square()), osmID: "w1"),
            Feature(id: 2, type: .bunker, polygon: CoordinatePath(square()), osmID: "w2"),
            Feature(id: 3, type: .bunker, polygon: CoordinatePath(square()), osmID: "w3"),
            Feature(id: 4, type: .water, polygon: CoordinatePath(square()), osmID: "w4"),
        ])
        var baseline = OSMBaseline(course: course)
        baseline.entries["w1"]?.tags = ["natural": "sand"]
        baseline.entries["w2"]?.tags = ["golf": "bunker", "natural": "sand"]
        // w3's tags are unknown.
        baseline.entries["w4"]?.tags = ["natural": "water"]

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes == [OSMFeatureChange(action: .modify, featureID: 1, type: .bunker, osmID: "w1", addsGolfTag: true)])
    }

    @Test func relationTypeChangeIsSent() {
        var course = makeCourse(features: [Feature(id: 1, type: .water, polygon: CoordinatePath(square()), osmID: "r1")])
        let baseline = OSMBaseline(course: course)
        course.features[0] = Feature(id: 1, type: .bunker, polygon: course.features[0].polygon, osmID: "r1")

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes == [OSMFeatureChange(action: .modify, featureID: 1, type: .bunker, osmID: "r1", oldType: .water)])
    }
}

@Suite("OSM change builder")
struct OSMChangeBuilderTests {
    @Test func tagsForEachType() {
        #expect(OSMChangeBuilder.tags(for: .fairway) == ["golf": "fairway"])
        #expect(OSMChangeBuilder.tags(for: .green) == ["golf": "green"])
        #expect(OSMChangeBuilder.tags(for: .tee) == ["golf": "tee"])
        #expect(OSMChangeBuilder.tags(for: .bunker) == ["golf": "bunker", "natural": "sand"])
        #expect(OSMChangeBuilder.tags(for: .water) == ["golf": "water_hazard", "natural": "water"])
        #expect(OSMChangeBuilder.tags(for: .centerline, hole: Hole(number: 7, par: 3)) == ["golf": "hole", "ref": "7", "par": "3"])
    }

    @Test func typeChangeKeepsOtherTags() {
        let tags = ["golf": "bunker", "natural": "sand", "name": "Church Pews"]
        #expect(OSMChangeBuilder.retag(tags, from: .bunker, to: .green) == ["golf": "green", "name": "Church Pews"])
    }

    @Test func waterWithoutGolfTag() {
        let tags = ["natural": "water", "water": "pond"]
        #expect(OSMChangeBuilder.retag(tags, from: .water, to: .bunker) == ["golf": "bunker", "natural": "sand", "water": "pond"])
    }

    @Test func unchangedPointsReuseNodesAndAreaIsClosed() {
        let points = square()
        let existing = points.enumerated().map { OSMNode(id: 100 + $0.offset, version: 1, lat: $0.element.lat, lon: $0.element.lon) }
        var nextID = -1

        let (refs, newNodes) = OSMChangeBuilder.nodeList(for: points, closed: true, existing: existing, nextID: &nextID)

        #expect(refs == [100, 101, 102, 103, 100])
        #expect(newNodes.isEmpty)
    }

    @Test func movedPointMakesNewNode() {
        let points = square()
        let existing = points.enumerated().map { OSMNode(id: 100 + $0.offset, version: 1, lat: $0.element.lat, lon: $0.element.lon) }
        var moved = points
        moved[1] = point(north: -3, east: 10)
        var nextID = -1

        let (refs, newNodes) = OSMChangeBuilder.nodeList(for: moved, closed: true, existing: existing, nextID: &nextID)

        #expect(refs == [100, -1, 102, 103, 100])
        #expect(newNodes.map(\.id) == [-1])
        #expect(nextID == -2)
    }

    @Test func centerlineIsNotClosed() {
        var nextID = -1
        let (refs, _) = OSMChangeBuilder.nodeList(for: [point(north: 0), point(north: 300)], closed: false, existing: [], nextID: &nextID)
        #expect(refs == [-1, -2])
    }

    @Test func uploadXMLHasCreateModifyAndDelete() {
        let points = square()
        let nodes = Dictionary(uniqueKeysWithValues: points.enumerated().map {
            (100 + $0.offset, OSMNode(id: 100 + $0.offset, version: 2, lat: $0.element.lat, lon: $0.element.lon))
        })
        let way = OSMWay(id: 10, version: 5, nodes: [100, 101, 102, 103, 100], tags: ["golf": "bunker", "natural": "sand"])
        let deletedWay = OSMWay(id: 11, version: 3, nodes: [100, 101, 102, 103, 100], tags: ["golf": "tee"])
        let fetched = OSMFetchedElements(ways: [
            10: OSMWayFull(way: way, nodes: nodes),
            11: OSMWayFull(way: deletedWay, nodes: nodes),
        ])
        var moved = points
        moved[1] = point(north: -3, east: 10)
        let course = makeCourse(features: [
            Feature(id: 1, type: .bunker, polygon: CoordinatePath(moved), osmID: "w10"),
            Feature(id: 2, type: .green, polygon: CoordinatePath(square(north: 50))),
        ])
        let changes = [
            OSMFeatureChange(action: .modify, featureID: 1, type: .bunker, osmID: "w10", pointsChanged: true),
            OSMFeatureChange(action: .create, featureID: 2, type: .green, osmID: nil),
            OSMFeatureChange(action: .delete, featureID: nil, type: .tee, osmID: "w11"),
        ]

        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: 99)

        #expect(upload.xml.contains("<way id=\"10\" version=\"5\" changeset=\"99\">"))
        #expect(upload.xml.contains("<nd ref=\"-1\"/>"))
        #expect(upload.xml.contains("<delete if-unused=\"true\">"))
        #expect(upload.xml.contains("<way id=\"11\" version=\"3\" changeset=\"99\"/>"))
        // Node 101 left way 10 and way 11 is deleted, so 101 is deleted. The others are still in way 10.
        #expect(upload.xml.contains("<node id=\"101\" version=\"2\" changeset=\"99\""))
        #expect(!upload.xml.contains("<node id=\"100\" version=\"2\""))
        #expect(upload.xml.contains("<tag k=\"golf\" v=\"green\"/>"))
        #expect(upload.createdWays.values.contains(2))
        #expect(upload.xml.firstRange(of: "<create>")!.lowerBound < upload.xml.firstRange(of: "<modify>")!.lowerBound)
        #expect(upload.xml.firstRange(of: "<modify>")!.lowerBound < upload.xml.firstRange(of: "<delete")!.lowerBound)
    }

    @Test func conflictsWhenVersionChanged() {
        let baseline = OSMBaseline(entries: [
            "w10": .init(osmID: "w10", version: 5, type: .bunker, points: []),
            "w11": .init(osmID: "w11", version: nil, type: .tee, points: []),
        ])
        let fetched = OSMFetchedElements(ways: [
            10: OSMWayFull(way: OSMWay(id: 10, version: 6, nodes: [], tags: [:]), nodes: [:]),
            11: OSMWayFull(way: OSMWay(id: 11, version: 9, nodes: [], tags: [:]), nodes: [:]),
        ])
        let changes = [
            OSMFeatureChange(action: .modify, featureID: 1, type: .bunker, osmID: "w10", pointsChanged: true),
            OSMFeatureChange(action: .delete, featureID: nil, type: .tee, osmID: "w11"),
        ]

        #expect(OSMChangeBuilder.conflicts(in: changes, baseline: baseline, fetched: fetched) == ["w10"])
    }

    @Test func applyResultSetsIDsAndBaseline() {
        var course = makeCourse(features: [
            Feature(id: 1, type: .green, polygon: CoordinatePath(square()), osmID: "w10"),
            Feature(id: 2, type: .tee, polygon: CoordinatePath(square(north: 50))),
        ])
        let baseline = OSMBaseline(entries: [
            "w10": .init(osmID: "w10", version: 5, type: .bunker, points: []),
            "w11": .init(osmID: "w11", version: 3, type: .tee, points: []),
        ])
        let changes = [
            OSMFeatureChange(action: .modify, featureID: 1, type: .green, osmID: "w10", oldType: .bunker, pointsChanged: true),
            OSMFeatureChange(action: .create, featureID: 2, type: .tee, osmID: nil),
            OSMFeatureChange(action: .delete, featureID: nil, type: .tee, osmID: "w11"),
        ]
        let upload = OSMChangeBuilder.Upload(xml: "", createdWays: [-5: 2], sent: [
            "w10": OSMElementDetails(tags: ["golf": "green", "name": "Practice"]),
            "w-5": OSMElementDetails(tags: ["golf": "tee"]),
        ])
        let diff = [
            OSMDiffEntry(type: "way", oldID: 10, newID: 10, newVersion: 6),
            OSMDiffEntry(type: "way", oldID: -5, newID: 500, newVersion: 1),
            OSMDiffEntry(type: "way", oldID: 11, newID: nil, newVersion: nil),
        ]

        let result = OSMChangeBuilder.apply(diff, upload: upload, changes: changes, course: &course, baseline: baseline)

        #expect(course.features[1].osmID == "w500")
        #expect(result.entries["w500"]?.version == 1)
        #expect(result.entries["w10"]?.version == 6)
        #expect(result.entries["w10"]?.type == .green)
        #expect(result.entries["w10"]?.points.count == 4)
        #expect(result.entries["w10"]?.tags == ["golf": "green", "name": "Practice"])
        #expect(result.entries["w500"]?.tags == ["golf": "tee"])
        #expect(result.entries["w11"] == nil)
        #expect(OSMChangeDetector.changes(in: course, from: result).isEmpty)
    }

    @Test func golfTagIsAddedAndOtherTagsKept() {
        let fetched = OSMFetchedElements(
            ways: [1: OSMWayFull(way: OSMWay(id: 1, version: 2, nodes: [10, 11, 12, 10], tags: ["natural": "sand", "name": "Pit"]), nodes: [:])],
            relations: [9: OSMRelation(id: 9, version: 4, members: [], tags: ["natural": "sand", "type": "multipolygon"])]
        )
        let course = makeCourse(features: [
            Feature(id: 1, type: .bunker, polygon: CoordinatePath(square()), osmID: "w1"),
            Feature(id: 2, type: .bunker, polygon: CoordinatePath(square()), osmID: "r9"),
        ])
        let changes = [
            OSMFeatureChange(action: .modify, featureID: 1, type: .bunker, osmID: "w1", addsGolfTag: true),
            OSMFeatureChange(action: .modify, featureID: 2, type: .bunker, osmID: "r9", addsGolfTag: true),
        ]

        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: 7)

        #expect(upload.sent["w1"]?.tags == ["golf": "bunker", "natural": "sand", "name": "Pit"])
        #expect(upload.sent["r9"]?.tags == ["golf": "bunker", "natural": "sand", "type": "multipolygon"])
        #expect(upload.xml.contains("<way id=\"1\" version=\"2\" changeset=\"7\">\n    <nd ref=\"10\"/>"))

        var updated = course
        let baseline = OSMBaseline(course: course)
        let result = OSMChangeBuilder.apply(
            [OSMDiffEntry(type: "way", oldID: 1, newID: 1, newVersion: 3), OSMDiffEntry(type: "relation", oldID: 9, newID: 9, newVersion: 5)],
            upload: upload, changes: changes, course: &updated, baseline: baseline
        )
        #expect(result.entries["w1"]?.tags?["golf"] == "bunker")
        #expect(result.entries["r9"]?.version == 5)
        #expect(OSMChangeDetector.changes(in: updated, from: result).isEmpty)
    }

    @Test func diffResultParsing() {
        let xml = """
        <diffResult version="0.6">
          <node old_id="-1" new_id="900" new_version="1"/>
          <way old_id="10" new_id="10" new_version="6"/>
          <way old_id="11"/>
        </diffResult>
        """
        #expect(DiffResultParser.parse(Data(xml.utf8)) == [
            OSMDiffEntry(type: "node", oldID: -1, newID: 900, newVersion: 1),
            OSMDiffEntry(type: "way", oldID: 10, newID: 10, newVersion: 6),
            OSMDiffEntry(type: "way", oldID: 11, newID: nil, newVersion: nil),
        ])
    }
}

@Suite("OSM multipolygon")
struct OSMMultipolygonTests {
    /// A 100 m square fairway.
    private let fairwayPoints = [point(north: 0), point(north: 0, east: 100), point(north: 100, east: 100), point(north: 100)]

    @Test func greenInsideFairwayIsOffered() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let inside = Feature(id: 2, type: .green, polygon: CoordinatePath(square(north: 40).map { Coordinate(lat: $0.lat, lon: $0.lon + 0.0004) }), osmID: "w2")
        let course = makeCourse(features: [fairway, inside])

        #expect(OSMMultipolygon.containedGreens(in: fairway, course: course).map(\.id) == [2])
    }

    @Test func greenCrossingOutlineIsNotOffered() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let crossing = Feature(id: 2, type: .green, polygon: CoordinatePath(square(north: 95)), osmID: "w2")
        let newGreen = Feature(id: 3, type: .green, polygon: CoordinatePath(square(north: 40).map { Coordinate(lat: $0.lat, lon: $0.lon + 0.0004) }))
        let course = makeCourse(features: [fairway, crossing, newGreen])

        #expect(OSMMultipolygon.containedGreens(in: fairway, course: course).isEmpty)
    }

    @Test func greenMissingFromRelationFairwayIsOffered() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r1")
        let inside = Feature(id: 2, type: .green, polygon: CoordinatePath(square(north: 40).map { Coordinate(lat: $0.lat, lon: $0.lon + 0.0004) }), osmID: "w2")
        let course = makeCourse(features: [fairway, inside])
        let unknown = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [])])
        let missing = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [], members: [.init(type: "way", ref: 50, role: "outer")])])
        let present = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [], members: [.init(type: "way", ref: 2, role: "inner")])])

        #expect(OSMMultipolygon.missingGreens(in: fairway, course: course, baseline: unknown).map(\.id) == [2])
        #expect(OSMMultipolygon.missingGreens(in: fairway, course: course, baseline: missing).map(\.id) == [2])
        #expect(OSMMultipolygon.missingGreens(in: fairway, course: course, baseline: present).isEmpty)
    }

    @Test func relationUploadAddsMissingInnerGreens() {
        let relation = OSMRelation(
            id: 9, version: 3,
            members: [.init(type: "way", ref: 50, role: "outer"), .init(type: "way", ref: 2, role: "inner"), .init(type: "way", ref: 3, role: "")],
            tags: ["golf": "fairway", "type": "multipolygon"]
        )
        let fetched = OSMFetchedElements(relations: [9: relation])
        let course = makeCourse(features: [Feature(id: 5, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r9")])
        let changes = [OSMFeatureChange(action: .multipolygon, featureID: 5, type: .fairway, osmID: "r9", innerOSMIDs: ["w2", "w3", "w4"])]

        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: 7)

        #expect(upload.xml == """
        <osmChange version="0.6" generator="CourseBuilder">
        <modify>
          <relation id="9" version="3" changeset="7">
            <member type="way" ref="50" role="outer"/>
            <member type="way" ref="2" role="inner"/>
            <member type="way" ref="3" role="inner"/>
            <member type="way" ref="4" role="inner"/>
            <tag k="golf" v="fairway"/>
            <tag k="type" v="multipolygon"/>
          </relation>
        </modify>
        </osmChange>

        """)
        #expect(upload.createdRelations.isEmpty)
        #expect(upload.sent["r9"]?.members?.map(\.ref) == [50, 2, 3, 4])
    }

    @Test func relationUploadWithNoMissingGreensSendsNothing() {
        let relation = OSMRelation(id: 9, version: 3, members: [.init(type: "way", ref: 50, role: "outer"), .init(type: "way", ref: 2, role: "inner")], tags: [:])
        let course = makeCourse(features: [Feature(id: 5, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r9")])
        let changes = [OSMFeatureChange(action: .multipolygon, featureID: 5, type: .fairway, osmID: "r9", innerOSMIDs: ["w2"])]

        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: OSMFetchedElements(relations: [9: relation]), changesetID: 7)

        #expect(!upload.xml.contains("<relation"))
    }

    @Test func relationDeleteAlsoDeletesUntaggedOuterWays() {
        let relation = OSMRelation(
            id: 9, version: 3,
            members: [.init(type: "way", ref: 50, role: "outer"), .init(type: "way", ref: 51, role: "outer"), .init(type: "way", ref: 2, role: "inner")],
            tags: ["golf": "fairway", "type": "multipolygon"]
        )
        let fetched = OSMFetchedElements(
            ways: [
                50: OSMWayFull(way: OSMWay(id: 50, version: 4, nodes: [100, 101, 100], tags: [:]), nodes: [
                    100: OSMNode(id: 100, version: 1, lat: 40, lon: -105),
                    101: OSMNode(id: 101, version: 1, lat: 40.001, lon: -105),
                ]),
                51: OSMWayFull(way: OSMWay(id: 51, version: 2, nodes: [], tags: ["golf": "rough"]), nodes: [:]),
            ],
            relations: [9: relation]
        )
        let changes = [OSMFeatureChange(action: .delete, featureID: nil, type: .fairway, osmID: "r9")]

        let upload = OSMChangeBuilder.upload(for: changes, course: makeCourse(features: []), fetched: fetched, changesetID: 7)

        #expect(upload.xml == """
        <osmChange version="0.6" generator="CourseBuilder">
        <delete if-unused="true">
          <relation id="9" version="3" changeset="7"/>
          <way id="50" version="4" changeset="7"/>
          <node id="100" version="1" changeset="7" lat="40.0000000" lon="-105.0000000"/>
          <node id="101" version="1" changeset="7" lat="40.0010000" lon="-105.0000000"/>
        </delete>
        </osmChange>

        """)
    }

    @Test func applyRemovesDeletedRelation() {
        var course = makeCourse(features: [])
        let baseline = OSMBaseline(entries: ["r9": .init(osmID: "r9", version: 3, type: .fairway, points: [])])
        let changes = [OSMFeatureChange(action: .delete, featureID: nil, type: .fairway, osmID: "r9")]

        let result = OSMChangeBuilder.apply([], upload: .init(xml: "", createdWays: [:]), changes: changes, course: &course, baseline: baseline)

        #expect(result.entries.isEmpty)
    }

    @Test func unknownDetailsAreFilled() {
        let inner = OSMRelation.Member(type: "way", ref: 1, role: "inner")
        var baseline = OSMBaseline(entries: [
            "r9": .init(osmID: "r9", version: 1, type: .fairway, points: []),
            "r10": .init(osmID: "r10", version: 1, type: .fairway, points: [], tags: ["golf": "fairway"], members: []),
            "w1": .init(osmID: "w1", version: 1, type: .green, points: []),
            "w2": .init(osmID: "w2", version: 1, type: .tee, points: [], tags: ["golf": "tee"]),
        ])

        #expect(baseline.osmIDsWithUnknownDetails == ["r9", "w1"])

        baseline.fillDetails([
            "r9": OSMElementDetails(version: 5, tags: ["golf": "fairway"], members: [inner]),
            "r10": OSMElementDetails(version: 5, tags: [:], members: [inner]),
            "w1": OSMElementDetails(version: 5, tags: ["golf": "green"]),
        ])

        #expect(baseline.entries["r9"]?.innerOSMIDs == ["w1"])
        #expect(baseline.entries["r9"]?.version == 1)
        #expect(baseline.entries["r10"]?.tags == ["golf": "fairway"])
        #expect(baseline.entries["r10"]?.members == [])
        #expect(baseline.entries["w1"]?.tags == ["golf": "green"])
        #expect(baseline.osmIDsWithUnknownDetails.isEmpty)
    }

    @Test func applyRecordsRelationInnerGreens() {
        var course = makeCourse(features: [Feature(id: 5, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r9")])
        let baseline = OSMBaseline(
            entries: ["r9": .init(osmID: "r9", version: 3, type: .fairway, points: [])],
            pendingMultipolygons: [PendingMultipolygon(fairwayOSMID: "r9", innerOSMIDs: ["w2"])]
        )
        let changes = [OSMFeatureChange(action: .multipolygon, featureID: 5, type: .fairway, osmID: "r9", innerOSMIDs: ["w2"])]
        let diff = [OSMDiffEntry(type: "relation", oldID: 9, newID: 9, newVersion: 4)]
        let upload = OSMChangeBuilder.Upload(xml: "", createdWays: [:], sent: [
            "r9": OSMElementDetails(tags: ["golf": "fairway"], members: [.init(type: "way", ref: 50, role: "outer"), .init(type: "way", ref: 2, role: "inner")]),
        ])

        let result = OSMChangeBuilder.apply(diff, upload: upload, changes: changes, course: &course, baseline: baseline)

        #expect(course.features[0].osmID == "r9")
        #expect(result.entries["r9"]?.version == 4)
        #expect(result.entries["r9"]?.innerOSMIDs == ["w2"])
        #expect(result.pendingMultipolygons.isEmpty)
    }

    @Test func multipolygonUploadMovesTagsToNewRelation() {
        let fetched = OSMFetchedElements(ways: [
            1: OSMWayFull(way: OSMWay(id: 1, version: 3, nodes: [10, 11, 12, 10], tags: ["golf": "fairway", "landuse": "grass"]), nodes: [:]),
        ])
        let course = makeCourse(features: [Feature(id: 5, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")])
        let changes = [OSMFeatureChange(action: .multipolygon, featureID: 5, type: .fairway, osmID: "w1", innerOSMIDs: ["w2"])]

        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: 7)

        #expect(upload.xml.contains("""
          <relation id="-1" changeset="7">
            <member type="way" ref="1" role="outer"/>
            <member type="way" ref="2" role="inner"/>
            <tag k="golf" v="fairway"/>
            <tag k="landuse" v="grass"/>
            <tag k="type" v="multipolygon"/>
          </relation>
        """))
        #expect(upload.xml.contains("<way id=\"1\" version=\"3\" changeset=\"7\">\n    <nd ref=\"10\"/>\n    <nd ref=\"11\"/>\n    <nd ref=\"12\"/>\n    <nd ref=\"10\"/>\n  </way>"))
        #expect(upload.createdRelations == [-1: 5])
        #expect(upload.sent["w1"] == OSMElementDetails(tags: [:]))
        #expect(upload.sent["r-1"]?.tags == ["golf": "fairway", "landuse": "grass", "type": "multipolygon"])
    }

    @Test func relationPointEditChangesOuterWayOnly() {
        let nodes = Dictionary(uniqueKeysWithValues: fairwayPoints.enumerated().map {
            (100 + $0.offset, OSMNode(id: 100 + $0.offset, version: 1, lat: $0.element.lat, lon: $0.element.lon))
        })
        let outer = OSMWay(id: 50, version: 4, nodes: [100, 101, 102, 103, 100], tags: [:])
        let relation = OSMRelation(id: 9, version: 2, members: [.init(type: "way", ref: 50, role: "outer")], tags: ["type": "multipolygon", "golf": "fairway"])
        var fetched = OSMFetchedElements(ways: [50: OSMWayFull(way: outer, nodes: nodes)], relations: [9: relation])
        fetched.outerWays = [9: 50]
        var moved = fairwayPoints
        moved[2] = point(north: 120, east: 100)
        let course = makeCourse(features: [Feature(id: 1, type: .fairway, polygon: CoordinatePath(moved), osmID: "r9")])
        let changes = [OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "r9", pointsChanged: true)]

        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: 7)

        #expect(upload.xml.contains("<way id=\"50\" version=\"4\" changeset=\"7\">"))
        #expect(upload.xml.contains("<nd ref=\"-1\"/>"))
        #expect(!upload.xml.contains("<relation"))
        #expect(upload.xml.contains("<node id=\"102\" version=\"1\""))
    }

    @Test func applyGivesFairwayItsRelationID() {
        var course = makeCourse(features: [Feature(id: 5, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")])
        let baseline = OSMBaseline(
            entries: ["w1": .init(osmID: "w1", version: 3, type: .fairway, points: [])],
            pendingMultipolygons: [PendingMultipolygon(fairwayOSMID: "w1", innerOSMIDs: ["w2"])]
        )
        let changes = [OSMFeatureChange(action: .multipolygon, featureID: 5, type: .fairway, osmID: "w1", innerOSMIDs: ["w2"])]
        let upload = OSMChangeBuilder.Upload(xml: "", createdWays: [:], createdRelations: [-1: 5], sent: [
            "r-1": OSMElementDetails(tags: ["golf": "fairway", "type": "multipolygon"], members: [.init(type: "way", ref: 1, role: "outer"), .init(type: "way", ref: 2, role: "inner")]),
        ])
        let diff = [
            OSMDiffEntry(type: "relation", oldID: -1, newID: 800, newVersion: 1),
            OSMDiffEntry(type: "way", oldID: 1, newID: 1, newVersion: 4),
        ]

        let result = OSMChangeBuilder.apply(diff, upload: upload, changes: changes, course: &course, baseline: baseline)

        #expect(course.features[0].osmID == "r800")
        #expect(result.entries["w1"] == nil)
        #expect(result.entries["r800"]?.version == 1)
        #expect(result.entries["r800"]?.innerOSMIDs == ["w2"])
        #expect(result.entries["r800"]?.tags == ["golf": "fairway", "type": "multipolygon"])
        #expect(result.pendingMultipolygons.isEmpty)
        #expect(OSMChangeDetector.changes(in: course, from: result).isEmpty)
    }

    @Test func relationKeepsVersionWhenOnlyOuterWayChanged() {
        var course = makeCourse(features: [Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r9")])
        let baseline = OSMBaseline(entries: ["r9": .init(osmID: "r9", version: 2, type: .fairway, points: [])])
        let changes = [OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "r9", pointsChanged: true)]
        let diff = [OSMDiffEntry(type: "way", oldID: 50, newID: 50, newVersion: 5)]

        let result = OSMChangeBuilder.apply(diff, upload: .init(xml: "", createdWays: [:]), changes: changes, course: &course, baseline: baseline)

        #expect(result.entries["r9"]?.version == 2)
        #expect(result.entries["r9"]?.points.count == 4)
    }
}

@Suite("OSM baseline store")
struct OSMBaselineStoreTests {
    @Test func createsBaselineForCourseWithoutOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OSMBaselineStore(directory: directory)
        let course = makeCourse(features: [
            Feature(id: 1, type: .green, polygon: CoordinatePath(square()), osmID: "w1"),
            Feature(id: 2, type: .tee, polygon: CoordinatePath(square())),
        ])

        let baseline = try store.loadOrCreate(for: course)

        #expect(Array(baseline.entries.keys) == ["w1"])
        #expect(baseline.entries["w1"]?.version == nil)
        #expect(try store.load(courseID: course.id) == baseline)
    }

    @Test func revertRestoresTypeAndPoints() {
        let original = Feature(id: 1, type: .bunker, polygon: CoordinatePath(square()), osmID: "w1")
        let entry = OSMBaseline.Entry(feature: original, osmID: "w1", details: OSMElementDetails(version: 3, tags: [:]))
        var moved = square()
        moved[0] = point(north: -5)
        let edited = Feature(id: 1, type: .water, polygon: CoordinatePath(moved), osmID: "w1")

        #expect(entry.differs(from: edited))
        #expect(!entry.differs(from: original))

        let reverted = entry.reverted(edited)
        #expect(reverted.type == .bunker)
        #expect(reverted.osmID == "w1")
        #expect(!entry.differs(from: reverted))
    }

    @Test func undoRevertPutsEditsBack() {
        var moved = square()
        moved[0] = point(north: -5)
        let edited = Feature(id: 1, type: .water, polygon: CoordinatePath(moved), osmID: "w1")
        var course = makeCourse(features: [Feature(id: 1, type: .bunker, polygon: CoordinatePath(square()), osmID: "w1")])

        #expect(PolygonEditorOperations.undo(.reverted(edited), in: &course))
        #expect(course.features[0] == edited)
    }

    @Test func readsBaselineWithoutPendingMultipolygons() throws {
        let json = #"{"entries": {"w1": {"osmID": "w1", "type": "green", "points": [[40, -105]]}}}"#
        let baseline = try JSONDecoder().decode(OSMBaseline.self, from: Data(json.utf8))
        #expect(baseline.entries["w1"]?.type == .green)
        #expect(baseline.pendingMultipolygons.isEmpty)
    }
}

@Suite("Publish dialog")
struct PublishToOSMSheetTests {
    @Test func defaultCommentHasBlankLinesThenFooter() {
        let date = Date(timeIntervalSince1970: 1_792_619_528) // 2026-10-21T21:52:08Z
        #expect(PublishToOSMSheet.defaultComment(userName: "pat", date: date) == "\n\nEdited by pat using CourseBuilder - 2026-10-21T21:52:08Z")
    }

    @Test func detailText() {
        #expect(PublishToOSMSheet.detail(for: OSMFeatureChange(action: .modify, featureID: 1, type: .water, osmID: "w1", oldType: .bunker, pointsChanged: true)) == "points, type, was bunker")
        #expect(PublishToOSMSheet.detail(for: OSMFeatureChange(action: .modify, featureID: 1, type: .bunker, osmID: "w1", addsGolfTag: true)) == "adds golf=bunker")
    }
}

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

    @Test func movedCenterlineDoesNotShareNodes() {
        // The centerline's first point is moved onto a corner of the tee.
        let tee = Feature(id: 1, type: .tee, polygon: CoordinatePath(square()), osmID: "w1")
        let line = Feature(id: 2, type: .centerline, polygon: CoordinatePath([point(north: 5, east: 5), point(north: 200, east: 5)]), osmID: "w2")
        var course = makeCourse(features: [tee, line])
        let baseline = OSMBaseline(course: course)
        course.features[1].polygon = CoordinatePath([square()[0], point(north: 200, east: 5)])

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes.map(\.osmID) == ["w2"])
        #expect(changes.first?.pointsChanged == true)
        #expect(changes.first?.sharedNodeOSMIDs == [])
    }

    @Test func movedFeatureDoesNotShareNodesWithCenterline() {
        // A corner of the tee is moved onto the centerline's first point.
        let tee = Feature(id: 1, type: .tee, polygon: CoordinatePath(square()), osmID: "w1")
        let line = Feature(id: 2, type: .centerline, polygon: CoordinatePath([point(north: 5, east: 5), point(north: 200, east: 5)]), osmID: "w2")
        var course = makeCourse(features: [tee, line])
        let baseline = OSMBaseline(course: course)
        course.features[0].polygon = CoordinatePath([point(north: 5, east: 5)] + square().dropFirst())

        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes.map(\.osmID) == ["w1"])
        #expect(changes.first?.pointsChanged == true)
        #expect(changes.first?.sharedNodeOSMIDs == [])
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

    /// A square with its south-west corner `north` and `east` meters from the fairway's.
    private func box(north: Double, east: Double, size: Double = 10) -> CoordinatePath {
        CoordinatePath([
            point(north: north, east: east), point(north: north, east: east + size),
            point(north: north + size, east: east + size), point(north: north + size, east: east),
        ])
    }

    @Test func featuresInsideFairwayWayBecomeInnerMembers() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let green = Feature(id: 2, type: .green, polygon: box(north: 70, east: 40), osmID: "w2")
        let bunker = Feature(id: 3, type: .bunker, polygon: box(north: 40, east: 20), osmID: "w3")
        let water = Feature(id: 4, type: .water, polygon: box(north: 10, east: 60), osmID: "w4")
        let tee = Feature(id: 5, type: .tee, polygon: box(north: 10, east: 20), osmID: "w5")
        let course = makeCourse(features: [fairway, green, bunker, water, tee])
        let baseline = OSMBaseline(course: course)

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).map(\.id) == [2, 3, 4, 5])
        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: baseline).map(\.id) == [2, 3, 4, 5])
    }

    @Test func featuresOverlappingFairwayAreLeftOut() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let inside = Feature(id: 2, type: .bunker, polygon: box(north: 40, east: 40), osmID: "w2")
        let crossing = Feature(id: 3, type: .bunker, polygon: box(north: 95, east: 40), osmID: "w3")
        let outside = Feature(id: 4, type: .water, polygon: box(north: 40, east: 200), osmID: "w4")
        let covering = Feature(id: 5, type: .water, polygon: box(north: -50, east: -50, size: 200), osmID: "w5")
        let course = makeCourse(features: [fairway, inside, crossing, outside, covering])

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).map(\.id) == [2])
    }

    @Test func featureCuttingAcrossBendInFairwayIsLeftOut() {
        // An L-shaped fairway. The bunker's corners are all inside it, but its edges cut across the bend.
        let bend = [
            point(north: 0), point(north: 0, east: 100), point(north: 40, east: 100),
            point(north: 40, east: 40), point(north: 100, east: 40), point(north: 100),
        ]
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(bend), osmID: "w1")
        let cutting = Feature(id: 2, type: .bunker, polygon: CoordinatePath([
            point(north: 10, east: 90), point(north: 30, east: 90), point(north: 90, east: 30), point(north: 90, east: 10),
        ]), osmID: "w2")
        let course = makeCourse(features: [fairway, cutting])

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).isEmpty)
    }

    @Test func fairwayWithNothingInsideHasNoInnerMembers() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let away = Feature(id: 2, type: .green, polygon: box(north: 300, east: 40), osmID: "w2")
        let course = makeCourse(features: [fairway, away])
        let baseline = OSMBaseline(course: course)

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).isEmpty)
        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: baseline).isEmpty)
        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: makeCourse(features: [fairway])).isEmpty)
    }

    @Test func featuresNotInOSMAsWaysAreLeftOut() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let new = Feature(id: 2, type: .bunker, polygon: box(north: 40, east: 20))
        let relation = Feature(id: 3, type: .water, polygon: box(north: 40, east: 60), osmID: "r3")
        let course = makeCourse(features: [fairway, new, relation])

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).isEmpty)
    }

    @Test func featureInsideAnotherContainedFeatureIsLeftOut() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let water = Feature(id: 2, type: .water, polygon: box(north: 30, east: 30, size: 40), osmID: "w2")
        let island = Feature(id: 3, type: .green, polygon: box(north: 45, east: 45), osmID: "w3")
        let course = makeCourse(features: [fairway, water, island])

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).map(\.id) == [2])
    }

    @Test func fairwayRelationGetsFeaturesMissingFromIt() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r1")
        let green = Feature(id: 2, type: .green, polygon: box(north: 70, east: 40), osmID: "w2")
        let bunker = Feature(id: 3, type: .bunker, polygon: box(north: 40, east: 20), osmID: "w3")
        let water = Feature(id: 4, type: .water, polygon: box(north: 10, east: 60), osmID: "w4")
        let crossing = Feature(id: 5, type: .bunker, polygon: box(north: 95, east: 40), osmID: "w5")
        let course = makeCourse(features: [fairway, green, bunker, water, crossing])
        let members: [OSMRelation.Member] = [.init(type: "way", ref: 50, role: "outer"), .init(type: "way", ref: 2, role: "inner")]
        let baseline = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [], members: members)])

        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: baseline).map(\.id) == [3, 4])
    }

    @Test func fairwayRelationWithEveryFeatureHasNothingMissing() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r1")
        let green = Feature(id: 2, type: .green, polygon: box(north: 70, east: 40), osmID: "w2")
        let bunker = Feature(id: 3, type: .bunker, polygon: box(north: 40, east: 20), osmID: "w3")
        let course = makeCourse(features: [fairway, green, bunker])
        let members: [OSMRelation.Member] = [
            .init(type: "way", ref: 50, role: "outer"), .init(type: "way", ref: 2, role: "inner"), .init(type: "way", ref: 3, role: "inner"),
        ]
        let baseline = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [], members: members)])

        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: baseline).isEmpty)
    }

    @Test func multipolygonUploadAddsEveryContainedFeatureAsInner() {
        let fairwayWay = OSMWay(id: 1, version: 2, nodes: [10, 11, 12, 13, 10], tags: ["golf": "fairway"])
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let green = Feature(id: 2, type: .green, polygon: box(north: 70, east: 40), osmID: "w2")
        let bunker = Feature(id: 3, type: .bunker, polygon: box(north: 40, east: 20), osmID: "w3")
        let crossing = Feature(id: 4, type: .bunker, polygon: box(north: 95, east: 40), osmID: "w4")
        let course = makeCourse(features: [fairway, green, bunker, crossing])
        var baseline = OSMBaseline(course: course)
        let inner = OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: baseline)
        baseline.pendingMultipolygons = [PendingMultipolygon(fairwayOSMID: "w1", innerOSMIDs: inner.compactMap(\.osmID))]

        let changes = OSMChangeDetector.changes(in: course, from: baseline)
        #expect(changes == [OSMFeatureChange(action: .multipolygon, featureID: 1, type: .fairway, osmID: "w1", innerOSMIDs: ["w2", "w3"])])

        let fetched = OSMFetchedElements(ways: [1: OSMWayFull(way: fairwayWay, nodes: [:])])
        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: 7)
        #expect(upload.sent["r-1"]?.members == [
            .init(type: "way", ref: 1, role: "outer"),
            .init(type: "way", ref: 2, role: "inner"),
            .init(type: "way", ref: 3, role: "inner"),
        ])
    }

    @Test func overlappingBunkerIsCutOutOfFairwayEdge() {
        let bunker = Array(box(north: 95, east: 40))

        // The fairway keeps its four points and takes the bunker's two points that are inside it.
        #expect(OverlapCutOut.cutOut(bunker, from: fairwayPoints) == [
            point(north: 100), point(north: 0), point(north: 0, east: 100), point(north: 100, east: 100),
            bunker[1], bunker[0],
        ])
    }

    @Test func overlappingBunkerIsCutOutOfFairwayCorner() {
        let bunker = Array(box(north: 95, east: 95))

        // The fairway's corner inside the bunker is replaced by the bunker's corner inside the fairway.
        #expect(OverlapCutOut.cutOut(bunker, from: fairwayPoints) == [
            point(north: 100), point(north: 0), point(north: 0, east: 100), bunker[0],
        ])
    }

    @Test func fairwayEdgeWeavingAcrossBunkerIsCutOut() {
        // Hole 1 at Walnut Creek, in course file units. The fairway's west edge runs down the
        // bunker's east edge, crosses it five times, and already shares two points with it.
        func points(_ units: [(Int, Int)]) -> [Coordinate] {
            units.map { Coordinate(lat: Double($0.0) / 365_000, lon: Double($0.1) / 365_000) }
        }
        let bunker = points([
            (14562180, -38368293), (14562182, -38368296), (14562182, -38368299), (14562182, -38368303), (14562182, -38368307),
            (14562180, -38368310), (14562178, -38368312), (14562176, -38368313), (14562173, -38368314), (14562171, -38368314),
            (14562169, -38368315), (14562168, -38368316), (14562166, -38368316), (14562165, -38368317), (14562163, -38368319),
            (14562160, -38368321), (14562157, -38368322), (14562155, -38368322), (14562153, -38368320), (14562151, -38368319),
            (14562150, -38368314), (14562150, -38368307), (14562151, -38368299), (14562154, -38368295), (14562156, -38368292),
            (14562160, -38368289), (14562165, -38368286), (14562170, -38368285), (14562174, -38368286), (14562177, -38368289),
        ])
        let farEdge = points([(14562100, -38368200), (14562230, -38368200)])
        let fairway = points([
            (14562206, -38368309), (14562198, -38368306), (14562193, -38368302), (14562189, -38368299), (14562185, -38368295),
            (14562181, -38368290), (14562173, -38368286), (14562170, -38368285), (14562168, -38368285), (14562166, -38368286),
            (14562164, -38368286), (14562162, -38368288), (14562160, -38368289), (14562158, -38368290), (14562157, -38368292),
            (14562155, -38368293), (14562154, -38368294), (14562153, -38368295), (14562152, -38368296), (14562152, -38368297),
            (14562151, -38368298), (14562150, -38368299), (14562150, -38368300), (14562148, -38368302), (14562143, -38368305),
            (14562139, -38368308), (14562135, -38368309),
        ]) + farEdge

        let result = OverlapCutOut.cutOut(bunker, from: fairway)

        // The fairway now runs along the bunker's east edge on the bunker's own points.
        #expect(result != nil)
        for point in bunker[24...28] {
            #expect(result?.contains(point) == true)
        }
        // Every point is one of the fairway's or one of the bunker's, and none is inside the bunker.
        #expect(result?.allSatisfy { fairway.contains($0) || bunker.contains($0) } == true)
        #expect(result?.contains { !bunker.contains($0) && PolygonGeometry.contains($0, in: bunker) } == false)
        // The rest of the fairway is untouched.
        #expect(result?.contains(fairway[0]) == true)
        #expect(result?.contains(fairway[26]) == true)
        #expect(farEdge.allSatisfy { result?.contains($0) == true })
        // Nothing is left to fix.
        #expect(OverlapCutOut.cutOut(bunker, from: result ?? []) == nil)
    }

    @Test func featureSharingAnEdgeWithoutOverlapIsNotCutOut() {
        // A bunker outside the fairway that already shares the fairway's top edge points.
        let fairway = fairwayPoints + []
        let bunker = [fairwayPoints[2], fairwayPoints[3], point(north: 110), point(north: 110, east: 100)]

        #expect(OverlapCutOut.cutOut(bunker, from: fairway) == nil)
    }

    @Test func closedFairwayStaysClosedAfterCutOut() {
        let bunker = Array(box(north: 95, east: 40))
        let result = OverlapCutOut.cutOut(bunker, from: fairwayPoints + [fairwayPoints[0]])

        #expect(result?.count == 7)
        #expect(result?.first == result?.last)
    }

    @Test func featuresThatDoNotOverlapAreNotCutOut() {
        #expect(OverlapCutOut.cutOut(Array(box(north: 40, east: 40)), from: fairwayPoints) == nil)
        #expect(OverlapCutOut.cutOut(Array(box(north: 40, east: 200)), from: fairwayPoints) == nil)
        #expect(OverlapCutOut.cutOut(Array(box(north: -50, east: -50, size: 200)), from: fairwayPoints) == nil)
        // A strip across the whole fairway crosses its outline four times.
        #expect(OverlapCutOut.cutOut([
            point(north: 40, east: -10), point(north: 40, east: 110), point(north: 60, east: 110), point(north: 60, east: -10),
        ], from: fairwayPoints) == nil)
    }

    @Test func cleanUpCutsOutEveryOverlappingFeatureButNotFairways() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r1")
        let inside = Feature(id: 2, type: .green, polygon: box(north: 40, east: 40), osmID: "w2")
        let top = Feature(id: 3, type: .bunker, polygon: box(north: 95, east: 40), osmID: "w3")
        let bottom = Feature(id: 4, type: .bunker, polygon: box(north: -5, east: 40), osmID: "w4")
        let other = Feature(id: 5, type: .fairway, polygon: box(north: 40, east: 95), osmID: "w5")
        let course = makeCourse(features: [fairway, inside, top, bottom, other])

        #expect(OverlapCutOut.features(toCutOutOf: fairway, course: course).map(\.id) == [3, 4])
        let result = OverlapCutOut.cutOutAll(from: fairway, course: course)
        #expect(result?.count == 8)
        #expect(result?.contains(Array(top.polygon)[0]) == true)
        #expect(result?.contains(Array(bottom.polygon)[2]) == true)

        // Nothing overlaps once the fairway is reshaped, and the green inside it is still inside.
        var cleaned = course
        cleaned.features[0].polygon = CoordinatePath(result ?? [])
        #expect(OverlapCutOut.features(toCutOutOf: cleaned.features[0], course: cleaned).isEmpty)
        #expect(OverlapCutOut.cutOutAll(from: cleaned.features[0], course: cleaned) == nil)
        #expect(OSMMultipolygon.containedFeatures(in: cleaned.features[0], course: cleaned).map(\.id) == [2])
    }

    @Test func greenGivesWayToOverlappingBunkerAndWater() {
        let green = Feature(id: 1, type: .green, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let bunker = Feature(id: 2, type: .bunker, polygon: box(north: 95, east: 40), osmID: "w2")
        let water = Feature(id: 3, type: .water, polygon: box(north: -5, east: 40), osmID: "w3")
        let tee = Feature(id: 4, type: .tee, polygon: box(north: 40, east: 95), osmID: "w4")
        let fairway = Feature(id: 5, type: .fairway, polygon: box(north: 40, east: -5), osmID: "w5")
        let otherGreen = Feature(id: 6, type: .green, polygon: box(north: 95, east: 70), osmID: "w6")
        var course = makeCourse(features: [green, bunker, water, tee, fairway, otherGreen])
        let baseline = OSMBaseline(course: course)

        #expect(OverlapCutOut.features(toCutOutOf: green, course: course).map(\.id) == [2, 3])
        let result = OverlapCutOut.cutOutAll(from: green, course: course)
        #expect(result?.count == 8)
        #expect(result?.contains(Array(bunker.polygon)[0]) == true)
        #expect(result?.contains(Array(water.polygon)[2]) == true)

        // The reshaped green shares the bunker's and the water's nodes, and nothing is left to fix.
        course.features[0].polygon = CoordinatePath(result ?? [])
        let changes = OSMChangeDetector.changes(in: course, from: baseline)
        #expect(changes.map(\.osmID) == ["w1"])
        #expect(changes.first?.sharedNodeOSMIDs == ["w2", "w3"])
        #expect(OverlapCutOut.features(toCutOutOf: course.features[0], course: course).isEmpty)
    }

    @Test func bunkersWaterAndTeesNeverGiveWay() {
        let green = Feature(id: 1, type: .green, polygon: box(north: 95, east: 40), osmID: "w1")
        for type in [FeatureType.bunker, .water, .tee, .centerline] {
            let feature = Feature(id: 2, type: type, polygon: CoordinatePath(fairwayPoints), osmID: "w2")
            let course = makeCourse(features: [feature, green])
            #expect(OverlapCutOut.features(toCutOutOf: feature, course: course).isEmpty)
            #expect(OverlapCutOut.cutOutAll(from: feature, course: course) == nil)
        }
    }

    @Test func reshapedFairwaySharesTheBunkersNodes() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let bunker = Feature(id: 3, type: .bunker, polygon: box(north: 95, east: 40), osmID: "w3")
        var course = makeCourse(features: [fairway, bunker])
        let baseline = OSMBaseline(course: course)

        course.features[0].polygon = CoordinatePath(OverlapCutOut.cutOutAll(from: fairway, course: course) ?? [])
        let changes = OSMChangeDetector.changes(in: course, from: baseline)

        #expect(changes.count == 1)
        #expect(changes.first?.osmID == "w1")
        #expect(changes.first?.pointsChanged == true)
        #expect(changes.first?.sharedNodeOSMIDs == ["w3"])
    }

    @Test func centerlinesAreIgnored() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r1")
        // One line of play stays inside the fairway. The other starts and ends outside it.
        let inside = Feature(id: 2, type: .centerline, polygon: CoordinatePath([
            point(north: 10, east: 50), point(north: 50, east: 60), point(north: 90, east: 50),
        ]), osmID: "w2")
        let through = Feature(id: 3, type: .centerline, polygon: CoordinatePath([
            point(north: -50, east: 50), point(north: 50, east: 60), point(north: 150, east: 50),
        ]), osmID: "w3")
        let crossing = Feature(id: 4, type: .centerline, polygon: CoordinatePath([
            point(north: 50, east: 50), point(north: 120, east: 40), point(north: 120, east: 60),
        ]), osmID: "w4")
        let course = makeCourse(features: [fairway, inside, through, crossing])
        let baseline = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [])])

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).isEmpty)
        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: baseline).isEmpty)
        #expect(OverlapCutOut.features(toCutOutOf: fairway, course: course).isEmpty)
        #expect(OverlapCutOut.cutOutAll(from: fairway, course: course) == nil)
    }

    @Test func greenInsideFairwayIsOffered() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let inside = Feature(id: 2, type: .green, polygon: CoordinatePath(square(north: 40).map { Coordinate(lat: $0.lat, lon: $0.lon + 0.0004) }), osmID: "w2")
        let course = makeCourse(features: [fairway, inside])

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).map(\.id) == [2])
    }

    @Test func greenCrossingOutlineIsNotOffered() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let crossing = Feature(id: 2, type: .green, polygon: CoordinatePath(square(north: 95)), osmID: "w2")
        let newGreen = Feature(id: 3, type: .green, polygon: CoordinatePath(square(north: 40).map { Coordinate(lat: $0.lat, lon: $0.lon + 0.0004) }))
        let course = makeCourse(features: [fairway, crossing, newGreen])

        #expect(OSMMultipolygon.containedFeatures(in: fairway, course: course).isEmpty)
    }

    @Test func greenMissingFromRelationFairwayIsOffered() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "r1")
        let inside = Feature(id: 2, type: .green, polygon: CoordinatePath(square(north: 40).map { Coordinate(lat: $0.lat, lon: $0.lon + 0.0004) }), osmID: "w2")
        let course = makeCourse(features: [fairway, inside])
        let unknown = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [])])
        let missing = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [], members: [.init(type: "way", ref: 50, role: "outer")])])
        let present = OSMBaseline(entries: ["r1": .init(osmID: "r1", version: 3, type: .fairway, points: [], members: [.init(type: "way", ref: 2, role: "inner")])])

        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: unknown).map(\.id) == [2])
        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: missing).map(\.id) == [2])
        #expect(OSMMultipolygon.missingFeatures(in: fairway, course: course, baseline: present).isEmpty)
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

@Suite("Green cut out")
struct GreenCutOutTests {
    /// A 10 by 20 m fairway whose north edge runs along the north edge of the green.
    private let fairwayPoints = [
        point(north: 0), point(north: 0, east: 10), point(north: 20, east: 10),
        point(north: 20, east: 8), point(north: 20, east: 2), point(north: 20),
    ]
    /// A 6 by 10 m green in the north end of the fairway.
    private let greenPoints = [point(north: 10, east: 2), point(north: 10, east: 8), point(north: 20, east: 8), point(north: 20, east: 2)]

    @Test func greenSharingEdgeIsCutOut() {
        let result = GreenCutOut.cutOut(greenPoints, from: fairwayPoints)

        #expect(result == [
            fairwayPoints[4], fairwayPoints[5], fairwayPoints[0], fairwayPoints[1], fairwayPoints[2], fairwayPoints[3],
            greenPoints[1], greenPoints[0],
        ])
    }

    @Test func closedFairwayStaysClosed() {
        let result = GreenCutOut.cutOut(greenPoints + [greenPoints[0]], from: fairwayPoints + [fairwayPoints[0]])

        #expect(result?.count == 9)
        #expect(result?.first == result?.last)
    }

    @Test func greenOutsideSharedEdgeIsNotCutOut() {
        let outside = [point(north: 30, east: 2), point(north: 30, east: 8), point(north: 20, east: 8), point(north: 20, east: 2)]
        #expect(GreenCutOut.cutOut(outside, from: fairwayPoints) == nil)
    }

    @Test func greenNotSharingEdgeIsNotCutOut() {
        let inside = [point(north: 5, east: 2), point(north: 5, east: 8), point(north: 15, east: 8), point(north: 15, east: 2)]
        #expect(GreenCutOut.cutOut(inside, from: fairwayPoints) == nil)
    }

    @Test func onlyGreensAreOffered() {
        let fairway = Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1")
        let green = Feature(id: 2, type: .green, polygon: CoordinatePath(greenPoints), osmID: "w2")
        let bunker = Feature(id: 3, type: .bunker, polygon: CoordinatePath(greenPoints), osmID: "w3")
        let course = makeCourse(features: [fairway, green, bunker])

        #expect(GreenCutOut.greens(toCutOutOf: fairway, course: course).map(\.id) == [2])
        #expect(GreenCutOut.greens(toCutOutOf: green, course: course).isEmpty)
    }

    @Test func cutOutFairwaySharesGreenNodes() {
        var course = makeCourse(features: [
            Feature(id: 1, type: .fairway, polygon: CoordinatePath(fairwayPoints), osmID: "w1"),
            Feature(id: 2, type: .green, polygon: CoordinatePath(greenPoints), osmID: "w2"),
        ])
        let baseline = OSMBaseline(course: course)
        course.features[0].polygon = CoordinatePath(GreenCutOut.cutOut(greenPoints, from: fairwayPoints)!)

        let changes = OSMChangeDetector.changes(in: course, from: baseline)
        #expect(changes == [OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "w1", pointsChanged: true, sharedNodeOSMIDs: ["w2"])])

        let fairwayNodes = fairwayPoints.enumerated().map { OSMNode(id: 100 + $0.offset, version: 1, lat: $0.element.lat, lon: $0.element.lon) }
        let greenNodes = [
            OSMNode(id: 200, version: 1, lat: greenPoints[0].lat, lon: greenPoints[0].lon),
            OSMNode(id: 201, version: 1, lat: greenPoints[1].lat, lon: greenPoints[1].lon),
            fairwayNodes[3], fairwayNodes[4],
        ]
        let fetched = OSMFetchedElements(ways: [
            1: OSMWayFull(way: OSMWay(id: 1, version: 1, nodes: [100, 101, 102, 103, 104, 105, 100], tags: ["golf": "fairway"]),
                          nodes: Dictionary(uniqueKeysWithValues: fairwayNodes.map { ($0.id, $0) })),
            2: OSMWayFull(way: OSMWay(id: 2, version: 1, nodes: [200, 201, 103, 104, 200], tags: ["golf": "green"]),
                          nodes: Dictionary(uniqueKeysWithValues: greenNodes.map { ($0.id, $0) })),
        ])

        let upload = OSMChangeBuilder.upload(for: changes, course: course, fetched: fetched, changesetID: 7)

        let refs = [104, 105, 100, 101, 102, 103, 201, 200, 104].map { "    <nd ref=\"\($0)\"/>\n" }.joined()
        #expect(upload.xml.contains("<way id=\"1\" version=\"1\" changeset=\"7\">\n" + refs))
        #expect(!upload.xml.contains("<create>"))
        #expect(!upload.xml.contains("<delete"))
        #expect(!upload.xml.contains("<way id=\"2\""))
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

    @Test func multipolygonDetailNamesTheFeaturesCutOut() {
        let course = makeCourse(features: [
            Feature(id: 1, type: .fairway, polygon: CoordinatePath(square()), osmID: "r1"),
            Feature(id: 12, type: .green, polygon: CoordinatePath(square()), osmID: "w12"),
            Feature(id: 14, type: .bunker, polygon: CoordinatePath(square()), osmID: "w14"),
            Feature(id: 15, type: .bunker, polygon: CoordinatePath(square()), osmID: "w15"),
        ])
        let one = OSMFeatureChange(action: .multipolygon, featureID: 1, type: .fairway, osmID: "r1", innerOSMIDs: ["w14"])
        let many = OSMFeatureChange(action: .multipolygon, featureID: 1, type: .fairway, osmID: "r1", innerOSMIDs: ["w14", "w12", "w15"])

        #expect(PublishToOSMSheet.actionName(.multipolygon) == "Cut out")
        #expect(PublishToOSMSheet.detail(for: one, in: course) == "Fairway no longer covers bunker #14.")
        #expect(PublishToOSMSheet.detail(for: many, in: course) == "Fairway no longer covers green #12 and bunkers #14 and #15.")
        #expect(PublishToOSMSheet.detail(for: one) == "Fairway no longer covers the features inside it.")
    }

    @Test func reshapedFairwayDetailNamesTheFeatureItFollows() {
        let course = makeCourse(features: [
            Feature(id: 1, type: .fairway, polygon: CoordinatePath(square()), osmID: "r1"),
            Feature(id: 14, type: .bunker, polygon: CoordinatePath(square()), osmID: "w14"),
        ])
        let change = OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "r1", pointsChanged: true, sharedNodeOSMIDs: ["w14"])

        #expect(PublishToOSMSheet.detail(for: change, in: course) == "points, edge now follows bunker #14")
    }
}

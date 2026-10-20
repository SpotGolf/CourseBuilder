import CoreGraphics
import CoreLocation
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct PolygonEditorOperationsTests {
    @Test func adjacentSelectionStartsAtExpectedEndAndWraps() {
        #expect(PolygonEditorOperations.adjacentVertexIndex(current: nil, count: 4, offset: 1) == 0)
        #expect(PolygonEditorOperations.adjacentVertexIndex(current: nil, count: 4, offset: -1) == 3)
        #expect(PolygonEditorOperations.adjacentVertexIndex(current: 3, count: 4, offset: 1) == 0)
        #expect(PolygonEditorOperations.adjacentVertexIndex(current: 0, count: 4, offset: -1) == 3)
        #expect(PolygonEditorOperations.adjacentVertexIndex(current: nil, count: 0, offset: 1) == nil)
    }

    @Test func nearestVertexUsesPointerCoordinate() {
        let polygon = [
            Coordinate(lat: 0, lon: 0),
            Coordinate(lat: 0, lon: 1),
            Coordinate(lat: 1, lon: 1),
        ]

        let index = PolygonEditorOperations.nearestVertexIndex(
            to: Coordinate(lat: 0.9, lon: 0.9),
            in: polygon
        )

        #expect(index == 2)
    }

    @Test func nearestEdgeProjectsPointAndReturnsInsertionIndex() {
        let polygon = square

        let edge = PolygonEditorOperations.nearestEdge(
            to: CGPoint(x: 5, y: 2),
            polygon: polygon,
            maximumDistance: 3,
            convert: screenPoint
        )

        #expect(edge?.insertionIndex == 1)
        #expect(edge?.point == CGPoint(x: 5, y: 0))
    }

    @Test func nearestEdgeIncludesClosingSegment() {
        let edge = PolygonEditorOperations.nearestEdge(
            to: CGPoint(x: -1, y: 5),
            polygon: square,
            maximumDistance: 2,
            convert: screenPoint
        )

        #expect(edge?.insertionIndex == 4)
        #expect(edge?.point == CGPoint(x: 0, y: 5))
    }

    @Test func nearestEdgeRejectsDistantDoubleClick() {
        let edge = PolygonEditorOperations.nearestEdge(
            to: CGPoint(x: 50, y: 50),
            polygon: square,
            maximumDistance: 10,
            convert: screenPoint
        )

        #expect(edge == nil)
    }

    @Test func deleteAndRestorePreservesFeatureAndHoleOrdering() throws {
        let first = Feature(id: 1, type: .tee, polygon: CoordinatePath(square))
        let deleted = Feature(id: 2, type: .fairway, polygon: CoordinatePath(square))
        let last = Feature(id: 3, type: .green, polygon: CoordinatePath(square))
        var course = makeCourse(features: [first, deleted, last])
        course.subCourses[0].holes[0].features = [1, 2, 3]
        course.subCourses[0].holes[1].features = [2, 3]
        course.subCourses[0].holes[0].tees = ["Blue": 1, "White": 2]
        course.subCourses[0].holes[1].tees = ["White": 2]

        let record = try #require(PolygonEditorOperations.deleteFeature(id: 2, from: &course))

        #expect(course.features.map(\.id) == [1, 3])
        #expect(course.subCourses[0].holes[0].features == [1, 3])
        #expect(course.subCourses[0].holes[1].features == [3])
        #expect(course.subCourses[0].holes[0].tees == ["Blue": 1])
        #expect(course.subCourses[0].holes[1].tees.isEmpty)

        #expect(PolygonEditorOperations.restoreFeature(record, to: &course))
        #expect(course.features.map(\.id) == [1, 2, 3])
        #expect(course.subCourses[0].holes[0].features == [1, 2, 3])
        #expect(course.subCourses[0].holes[1].features == [2, 3])
        #expect(course.subCourses[0].holes[0].tees == ["Blue": 1, "White": 2])
        #expect(course.subCourses[0].holes[1].tees == ["White": 2])
    }

    @Test func restoringSameDeletionTwiceIsRejected() throws {
        var course = makeCourse(features: [Feature(id: 2, type: .fairway, polygon: CoordinatePath(square))])
        let record = try #require(PolygonEditorOperations.deleteFeature(id: 2, from: &course))

        #expect(PolygonEditorOperations.restoreFeature(record, to: &course))
        #expect(!PolygonEditorOperations.restoreFeature(record, to: &course))
        #expect(course.features.map(\.id) == [2])
    }

    @Test func addFeatureAddsToCourseAndHole() {
        var course = makeCourse(features: [Feature(id: 5, type: .tee, polygon: CoordinatePath(square))])
        course.subCourses[0].holes[1].features = [5]

        let feature = PolygonEditorOperations.addFeature(type: .bunker, polygon: square, subCourseIndex: 0, holeIndex: 1, to: &course)

        #expect(feature.id == 6)
        #expect(course.features.map(\.id) == [5, 6])
        #expect(course.subCourses[0].holes[1].features == [5, 6])
        #expect(course.subCourses[0].holes[0].features.isEmpty)
    }

    @Test func addFeatureWithoutValidHoleOnlyAddsToCourse() {
        var course = makeCourse(features: [])
        PolygonEditorOperations.addFeature(type: .green, polygon: square, subCourseIndex: 0, holeIndex: 9, to: &course)
        #expect(course.features.map(\.id) == [1])
        #expect(course.subCourses[0].holes.allSatisfy { $0.features.isEmpty })
    }

    @Test func undoReplacedPolygonRestoresOldOutline() {
        let oldPolygon = square
        var course = makeCourse(features: [Feature(id: 1, type: .bunker, polygon: CoordinatePath(oldPolygon))])
        course.features[0].polygon = CoordinatePath(oldPolygon.prefix(3))

        #expect(PolygonEditorOperations.undo(.replacedPolygon(featureID: 1, oldPolygon: oldPolygon), in: &course))
        #expect(Array(course.features[0].polygon) == oldPolygon)
        #expect(!PolygonEditorOperations.undo(.replacedPolygon(featureID: 9, oldPolygon: oldPolygon), in: &course))
    }

    @Test func undoAddedFeatureRemovesFeatureAndHoleReference() {
        var course = makeCourse(features: [Feature(id: 1, type: .tee, polygon: CoordinatePath(square)), Feature(id: 2, type: .bunker, polygon: CoordinatePath(square))])
        course.subCourses[0].holes[0].features = [1, 2]

        #expect(PolygonEditorOperations.undo(.added(featureID: 2), in: &course))
        #expect(course.features.map(\.id) == [1])
        #expect(course.subCourses[0].holes[0].features == [1])
        #expect(!PolygonEditorOperations.undo(.added(featureID: 2), in: &course))
    }

    @Test func undoDeletedRestoresFeature() throws {
        var course = makeCourse(features: [Feature(id: 2, type: .fairway, polygon: CoordinatePath(square))])
        let record = try #require(PolygonEditorOperations.deleteFeature(id: 2, from: &course))

        #expect(PolygonEditorOperations.undo(.deleted(record), in: &course))
        #expect(course.features.map(\.id) == [2])
    }

    private var square: [Coordinate] {
        [
            Coordinate(lat: 0, lon: 0),
            Coordinate(lat: 0, lon: 10),
            Coordinate(lat: 10, lon: 10),
            Coordinate(lat: 10, lon: 0),
        ]
    }

    private func screenPoint(_ coordinate: CLLocationCoordinate2D) -> CGPoint? {
        CGPoint(x: coordinate.longitude, y: coordinate.latitude)
    }

    private func makeCourse(features: [Feature]) -> Course {
        Course(
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Denver",
                state: "CO",
                country: "US",
                coordinate: Coordinate(lat: 0, lon: 0)
            ),
            features: features,
            subCourses: [
                SubCourse(name: "Front", holes: [
                    Hole(number: 1, par: 4),
                    Hole(number: 2, par: 4),
                ])
            ]
        )
    }
}

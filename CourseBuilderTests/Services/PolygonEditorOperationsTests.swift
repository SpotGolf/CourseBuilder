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
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1),
            Coordinate(latitude: 1, longitude: 1),
        ]

        let index = PolygonEditorOperations.nearestVertexIndex(
            to: Coordinate(latitude: 0.9, longitude: 0.9),
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

    @Test func elevationAppliesOnlyToMatchingUnresolvedCoordinate() {
        let target = Coordinate(latitude: 1, longitude: 2)
        var course = makeCourse(features: [
            Feature(id: 7, type: .green, polygon: [target])
        ])

        let applied = PolygonEditorOperations.applyElevation(123.45, to: target, featureID: 7, in: &course)

        #expect(applied)
        #expect(course.features[0].polygon[0].elevation == 123.45)
    }

    @Test func staleElevationDoesNotOverwritePointMovedAgain() {
        let oldLocation = Coordinate(latitude: 1, longitude: 2)
        let newLocation = Coordinate(latitude: 3, longitude: 4)
        var course = makeCourse(features: [
            Feature(id: 7, type: .green, polygon: [newLocation])
        ])

        let applied = PolygonEditorOperations.applyElevation(123.45, to: oldLocation, featureID: 7, in: &course)

        #expect(!applied)
        #expect(course.features[0].polygon[0] == newLocation)
    }

    @Test func deleteAndRestorePreservesFeatureAndHoleOrdering() throws {
        let first = Feature(id: 1, type: .tee, polygon: square)
        let deleted = Feature(id: 2, type: .fairway, polygon: square)
        let last = Feature(id: 3, type: .green, polygon: square)
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
        var course = makeCourse(features: [Feature(id: 2, type: .fairway, polygon: square)])
        let record = try #require(PolygonEditorOperations.deleteFeature(id: 2, from: &course))

        #expect(PolygonEditorOperations.restoreFeature(record, to: &course))
        #expect(!PolygonEditorOperations.restoreFeature(record, to: &course))
        #expect(course.features.map(\.id) == [2])
    }

    private var square: [Coordinate] {
        [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 10),
            Coordinate(latitude: 10, longitude: 10),
            Coordinate(latitude: 10, longitude: 0),
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
                coordinate: Coordinate(latitude: 0, longitude: 0)
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

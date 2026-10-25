import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("Ignored features")
struct IgnoredFeaturesTests {
    private func makeCourse() -> Course {
        Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
            features: [
                Feature(id: 1, type: .green, polygon: [Coordinate(lat: 40, lon: -105)]),
                Feature(id: 2, type: .bunker, polygon: [Coordinate(lat: 40.1, lon: -105)], osmID: "w2"),
                Feature(id: 3, type: .water, polygon: [Coordinate(lat: 40.2, lon: -105)]),
                Feature(id: 4, type: .centerline, polygon: [Coordinate(lat: 40, lon: -105), Coordinate(lat: 40.3, lon: -105)]),
            ],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, features: [1], centerline: 4)])]
        )
    }

    @Test func ignoreMovesOnlyUnassociatedFeatures() {
        var course = makeCourse()
        var ignored: [Feature] = []

        IgnoredFeatures.ignore([1, 2, 3, 4], in: &course, ignored: &ignored)

        #expect(course.features.map(\.id) == [1, 4])
        #expect(ignored.map(\.id) == [2, 3])
    }

    @Test func restorePutsFeaturesBack() {
        var course = makeCourse()
        var ignored: [Feature] = []
        IgnoredFeatures.ignore([2, 3], in: &course, ignored: &ignored)

        IgnoredFeatures.restore([2], to: &course, ignored: &ignored)

        #expect(course.features.map(\.id) == [1, 4, 2])
        #expect(course.findFeature(id: 2)?.osmID == "w2")
        #expect(ignored.map(\.id) == [3])
    }

    @Test func restoreGivesTakenIDANewOne() {
        var course = makeCourse()
        var ignored: [Feature] = []
        IgnoredFeatures.ignore([3], in: &course, ignored: &ignored)
        course.features.append(Feature(id: 3, type: .tee, polygon: []))

        IgnoredFeatures.restore([3], to: &course, ignored: &ignored)

        #expect(course.features.filter { $0.type == .water }.map(\.id) == [5])
        #expect(ignored.isEmpty)
    }

    @Test func ignoredOSMFeatureIsNotDeletedFromOSM() {
        var course = makeCourse()
        let baseline = OSMBaseline(course: course)
        var ignored: [Feature] = []
        IgnoredFeatures.ignore([2], in: &course, ignored: &ignored)

        #expect(OSMChangeDetector.changes(in: course, from: baseline, ignoredOSMIDs: ["w2"]).allSatisfy { $0.action != .delete })
        #expect(OSMChangeDetector.changes(in: course, from: baseline).contains { $0.action == .delete && $0.osmID == "w2" })
    }

    @Test func nextSelectionAfterIgnore() {
        let order = [4, 7, 2, 9]
        #expect(IgnoredFeatures.nextSelection(afterRemoving: [7], from: order) == 2)
        #expect(IgnoredFeatures.nextSelection(afterRemoving: [4, 2], from: order) == 9)
        #expect(IgnoredFeatures.nextSelection(afterRemoving: [9], from: order) == 2)
        #expect(IgnoredFeatures.nextSelection(afterRemoving: [2, 9], from: order) == 7)
        #expect(IgnoredFeatures.nextSelection(afterRemoving: [4, 7, 2, 9], from: order) == nil)
        #expect(IgnoredFeatures.nextSelection(afterRemoving: [5], from: order) == nil)
    }

    @Test func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IgnoredFeatureStore(directory: directory)
        let id = UUID()

        #expect(try store.load(courseID: id).isEmpty)
        let features = [Feature(id: 2, type: .bunker, polygon: [Coordinate(lat: 40.1, lon: -105)], osmID: "w2")]
        try store.save(features, courseID: id)
        #expect(try store.load(courseID: id) == features)
    }
}

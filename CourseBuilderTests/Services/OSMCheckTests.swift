import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("OSM check")
struct OSMCheckTests {
    private func makeStore() -> OSMCheckStore {
        OSMCheckStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func makeCourse(features: [Feature] = []) -> Course {
        Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
            features: features
        )
    }

    @Test func newCourseIsCheckedOnce() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let course = makeCourse()

        #expect(OSMCheck.shouldCheck(course, store: store))
        try store.markChecked(courseID: course.id)
        #expect(!OSMCheck.shouldCheck(course, store: store))
        #expect(OSMCheck.shouldCheck(makeCourse(), store: store))
    }

    @Test func courseWithFeaturesIsNotChecked() {
        let course = makeCourse(features: [Feature(id: 1, type: .green, polygon: [Coordinate(lat: 40, lon: -105)])])
        #expect(!OSMCheck.shouldCheck(course, store: makeStore()))
    }

    @Test func resultHasCourseData() {
        let feature = OverpassAPIClient.ParsedFeature(type: .green, polygon: [Coordinate(lat: 40, lon: -105)])
        let centerline = OverpassAPIClient.ParsedCenterline(holeNumber: 1, coordinates: [])

        #expect(!OSMCheck.hasCourseData(.init(features: [], centerlines: [], courseBoundary: nil)))
        #expect(!OSMCheck.hasCourseData(.init(features: [], centerlines: [], courseBoundary: [Coordinate(lat: 40, lon: -105)])))
        #expect(OSMCheck.hasCourseData(.init(features: [feature], centerlines: [], courseBoundary: nil)))
        #expect(OSMCheck.hasCourseData(.init(features: [], centerlines: [centerline], courseBoundary: nil)))
    }
}

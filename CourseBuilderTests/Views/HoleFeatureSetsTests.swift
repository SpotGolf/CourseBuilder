import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("Hole feature sets")
struct HoleFeatureSetsTests {
    @Test func splitsFeaturesIntoCurrentHoleAndUnassociated() {
        var front = Hole(number: 1, par: 4)
        front.features = [3, 1]
        var back = Hole(number: 2, par: 3)
        back.features = [2]
        let course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 0, lon: 0)),
            features: [1, 2, 3, 4, 5].map { Feature(id: $0, type: .bunker, polygon: []) },
            subCourses: [SubCourse(name: "Front", holes: [front, back])]
        )

        let sets = HoleFeatureSets(course: course, hole: front)

        #expect(sets.current.map(\.id) == [1, 3])
        #expect(sets.currentIDs == [1, 3])
        #expect(sets.unassociated.map(\.id) == [4, 5])
        #expect(sets.unassociatedIDs == [4, 5])
    }

    @Test func noHoleShowsOnlyUnassociatedFeatures() {
        let course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 0, lon: 0)),
            features: [Feature(id: 1, type: .green, polygon: [])]
        )

        let sets = HoleFeatureSets(course: course, hole: nil)

        #expect(sets.current.isEmpty)
        #expect(sets.unassociated.map(\.id) == [1])
    }
}

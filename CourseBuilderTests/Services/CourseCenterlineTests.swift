import Testing
@testable import CourseBuilder
import CourseDataSwift

struct CourseCenterlineTests {
    private let line: CoordinatePath = [Coordinate(lat: 0, lon: 0), Coordinate(lat: 1, lon: 1)]

    @Test func setCenterlineAddsCenterlineFeature() throws {
        var course = makeCourse()

        course.setCenterline(line, osmID: "w9", subCourseIndex: 0, holeIndex: 0)

        let feature = try #require(course.subCourses[0].holes[0].centerline(from: course.features))
        #expect(feature.type == .centerline)
        #expect(feature.polygon == line)
        #expect(feature.osmID == "w9")
        #expect(course.centerlinePath(for: course.subCourses[0].holes[0]) == line)
    }

    @Test func setCenterlineReplacesExistingFeature() throws {
        var course = makeCourse()
        course.setCenterline(line, osmID: "w9", subCourseIndex: 0, holeIndex: 0)
        let id = try #require(course.subCourses[0].holes[0].centerline)

        let redrawn: CoordinatePath = [Coordinate(lat: 2, lon: 2), Coordinate(lat: 3, lon: 3)]
        course.setCenterline(redrawn, subCourseIndex: 0, holeIndex: 0)

        #expect(course.features.count == 1)
        #expect(course.subCourses[0].holes[0].centerline == id)
        #expect(course.features[0].polygon == redrawn)
        #expect(course.features[0].osmID == nil)
    }

    @Test func emptyCenterlineRemovesFeature() {
        var course = makeCourse()
        course.setCenterline(line, subCourseIndex: 0, holeIndex: 0)

        course.setCenterline([], subCourseIndex: 0, holeIndex: 0)

        #expect(course.features.isEmpty)
        #expect(course.subCourses[0].holes[0].centerline == nil)
    }

    @Test func updateCenterlineKeepsOSMID() {
        var course = makeCourse()
        course.setCenterline(line, osmID: "w9", subCourseIndex: 0, holeIndex: 0)

        course.updateCenterline(subCourseIndex: 0, holeIndex: 0) { $0.remove(at: 0) }

        #expect(course.features[0].polygon.count == 1)
        #expect(course.features[0].osmID == "w9")
    }

    private func makeCourse() -> Course {
        Course(
            name: "Test Course",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 0, lon: 0)),
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])]
        )
    }
}

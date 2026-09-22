import Testing
@testable import CourseBuilder
import CourseDataSwift

struct CourseIntegrityTests {
    @Test func validationReportsMissingContentAndDanglingReferences() {
        let validFeature = Feature(id: 1, type: .tee, polygon: [])
        var course = makeCourse(features: [validFeature])
        course.subCourses[0].holes[0].features = [1, 99]
        course.subCourses[0].holes[0].tees = ["Blue": 98]
        course.subCourses[0].holes[0].yardages = ["Blue": 400, "White": 375]

        let warnings = CourseIntegrity.validateCourse(course)

        #expect(warnings.contains("Hole 1: missing green polygon"))
        #expect(warnings.contains("Hole 1: missing fairway polygon"))
        #expect(warnings.contains("Hole 1: missing centerline"))
        #expect(warnings.contains("Hole 1: tee \"White\" has yardage but no polygon assigned"))
        #expect(warnings.contains("Hole 1: tee \"Blue\" references missing feature #98"))
        #expect(warnings.contains("Hole 1: references missing feature #99"))
    }

    @Test func repairRemovesOnlyDanglingReferences() {
        let tee = Feature(id: 1, type: .tee, polygon: [])
        var course = makeCourse(features: [tee])
        course.tees = [
            TeeDefinition(name: "Blue", color: "#0000FF"),
            TeeDefinition(name: "White", color: "#FFFFFF"),
        ]
        course.subCourses[0].holes[0].features = [1, 98, 99]
        course.subCourses[0].holes[0].tees = ["Blue": 1, "White": 98]
        course.subCourses[0].holes[0].yardages = ["Blue": 400, "White": 375]

        let report = CourseIntegrity.repairDanglingReferences(in: &course)

        #expect(report.removedFeatureReferences == 2)
        #expect(report.removedTeeAssignments == 1)
        #expect(report.madeChanges)
        #expect(report.actions == [
            "Hole 1: removed missing feature reference #98",
            "Hole 1: removed missing feature reference #99",
            "Hole 1: removed tee \"White\" assignment to missing feature #98",
        ])
        #expect(course.subCourses[0].holes[0].features == [1])
        #expect(course.subCourses[0].holes[0].tees == ["Blue": 1])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 400, "White": 375])
    }

    @Test func repairReportsNoChangesForValidReferences() {
        let tee = Feature(id: 1, type: .tee, polygon: [])
        var course = makeCourse(features: [tee])
        course.tees = [TeeDefinition(name: "Blue", color: "#0000FF")]
        course.subCourses[0].holes[0].features = [1]
        course.subCourses[0].holes[0].tees = ["Blue": 1]

        let report = CourseIntegrity.repairDanglingReferences(in: &course)

        #expect(!report.madeChanges)
        #expect(report.removedFeatureReferences == 0)
        #expect(report.removedTeeAssignments == 0)
        #expect(report.actions.isEmpty)
    }

    @Test func cleanupRemovesDataForUndefinedTees() {
        var course = makeCourse(features: [Feature(id: 1, type: .tee, polygon: [])])
        course.tees = [TeeDefinition(name: "Blue", color: "#0000FF")]
        course.subCourses[0].tees = [
            "Blue": SubCourseTee(),
            "Blue (Member)": SubCourseTee(),
        ]
        course.subCourses[0].holes[0].yardages = ["Blue": 400, "Blue (Member)": 390]
        course.subCourses[0].holes[0].tees = ["Blue": 1, "Blue (Member)": 1]

        let report = CourseIntegrity.cleanup(&course)

        #expect(report.removedYardages == 1)
        #expect(report.removedTeeAssignments == 1)
        #expect(report.removedSubCourseTees == 1)
        #expect(course.subCourses[0].tees.keys.sorted() == ["Blue"])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 400])
        #expect(course.subCourses[0].holes[0].tees == ["Blue": 1])
    }

    @Test func renameTeeMigratesEveryTeeKey() {
        var course = makeCourse(features: [Feature(id: 1, type: .tee, polygon: [])])
        course.tees = [TeeDefinition(name: "Blue (Member)", color: "#0000FF")]
        course.subCourses[0].tees = ["Blue (Member)": SubCourseTee()]
        course.subCourses[0].holes[0].yardages = ["Blue (Member)": 390]
        course.subCourses[0].holes[0].tees = ["Blue (Member)": 1]

        let renamed = CourseIntegrity.renameTee(at: 0, to: "Blue", in: &course)

        #expect(renamed)
        #expect(course.tees[0].name == "Blue")
        #expect(course.subCourses[0].tees.keys.sorted() == ["Blue"])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 390])
        #expect(course.subCourses[0].holes[0].tees == ["Blue": 1])
    }

    @Test func renameTeeRejectsDuplicateNameWithoutChangingData() {
        var course = makeCourse(features: [])
        course.tees = [
            TeeDefinition(name: "Blue", color: "#0000FF"),
            TeeDefinition(name: "White", color: "#FFFFFF"),
        ]
        course.subCourses[0].holes[0].yardages = ["White": 390]

        let renamed = CourseIntegrity.renameTee(at: 1, to: "Blue", in: &course)

        #expect(!renamed)
        #expect(course.tees.map(\.name) == ["Blue", "White"])
        #expect(course.subCourses[0].holes[0].yardages == ["White": 390])
    }

    @Test func removeTeeRemovesEveryTeeKey() {
        var course = makeCourse(features: [Feature(id: 1, type: .tee, polygon: [])])
        course.tees = [TeeDefinition(name: "Blue", color: "#0000FF")]
        course.subCourses[0].tees = ["Blue": SubCourseTee()]
        course.subCourses[0].holes[0].yardages = ["Blue": 400]
        course.subCourses[0].holes[0].tees = ["Blue": 1]

        CourseIntegrity.removeTee(at: 0, from: &course)

        #expect(course.tees.isEmpty)
        #expect(course.subCourses[0].tees.isEmpty)
        #expect(course.subCourses[0].holes[0].yardages.isEmpty)
        #expect(course.subCourses[0].holes[0].tees.isEmpty)
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
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )
    }
}

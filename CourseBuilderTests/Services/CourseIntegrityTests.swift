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

    @Test func validationReportsComboTeeProblems() {
        var course = comboCourse()
        course.comboTees.append(ComboTeeDefinition(name: "Gold/Blue", tees: ["Gold", "Blue"]))
        course.subCourses[0].holes[0].comboTees = ["Blue/White": "White", "Gold/Blue": "Red", "Old": "Blue"]
        course.subCourses[0].holes[0].tees = ["Blue": 1]

        let warnings = CourseIntegrity.validateCourse(course)

        #expect(warnings.contains("Hole 1: combo tee \"Blue/White\" plays from \"White\", which has no polygon assigned"))
        #expect(warnings.contains("Hole 1: combo tee \"Gold/Blue\" plays from \"Red\", which is not part of the combo"))
        #expect(warnings.contains("Hole 1: references undefined combo tee \"Old\""))
        #expect(warnings.contains("Combo tee \"Gold/Blue\" uses undefined tee \"Gold\""))

        course.subCourses[0].holes[0].comboTees = [:]
        #expect(CourseIntegrity.validateCourse(course).contains("Hole 1: combo tee \"Blue/White\" has no tee picked"))
    }

    @Test func validationAcceptsValidComboTee() {
        var course = comboCourse()
        course.subCourses[0].holes[0].tees = ["Blue": 1, "White": 1]

        let warnings = CourseIntegrity.validateCourse(course)

        #expect(!warnings.contains { $0.localizedCaseInsensitiveContains("combo") })
    }

    @Test func cleanupRemovesDanglingComboTeeData() {
        var course = comboCourse()
        course.comboTees.append(ComboTeeDefinition(name: "Gold/Blue", tees: ["Gold", "Blue"]))
        course.subCourses[0].comboTees["Gold/Blue"] = SubCourseTee()
        course.subCourses[0].holes[0].comboTees = ["Blue/White": "Red", "Gold/Blue": "Blue"]

        let report = CourseIntegrity.cleanup(&course)

        #expect(course.comboTees == [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "White"])])
        #expect(course.subCourses[0].comboTees.keys.sorted() == ["Blue/White"])
        #expect(course.subCourses[0].holes[0].comboTees.isEmpty)
        #expect(report.removedComboTees == 4)
        #expect(report.actions.contains("Removed combo tee \"Gold/Blue\" because it uses an undefined tee"))
        #expect(report.actions.contains("Hole 1: removed combo tee \"Blue/White\" assignment to \"Red\", which is not part of the combo"))
    }

    @Test func cleanupKeepsValidComboTees() {
        var course = comboCourse()
        let original = course

        let report = CourseIntegrity.cleanup(&course)

        #expect(course == original)
        #expect(report.removedComboTees == 0)
    }

    @Test func renameTeeUpdatesComboTees() {
        var course = comboCourse()

        #expect(CourseIntegrity.renameTee(at: 1, to: "Silver", in: &course))

        #expect(course.comboTees == [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "Silver"])])
        #expect(course.subCourses[0].holes[0].comboTees == ["Blue/White": "Silver"])
    }

    @Test func renameTeeRejectsComboTeeName() {
        var course = comboCourse()
        let original = course

        #expect(!CourseIntegrity.renameTee(at: 1, to: "Blue/White", in: &course))
        #expect(course == original)
    }

    @Test func removeTeeRemovesComboTeesThatUseIt() {
        var course = comboCourse()

        CourseIntegrity.removeTee(at: 1, from: &course)

        #expect(course.tees.map(\.name) == ["Blue"])
        #expect(course.comboTees.isEmpty)
        #expect(course.subCourses[0].comboTees.isEmpty)
        #expect(course.subCourses[0].holes[0].comboTees.isEmpty)
    }

    @Test func usageCountsTeeBoxesAndComboTees() {
        var course = comboCourse()
        course.subCourses[0].holes.append(Hole(number: 2, par: 3))
        course.subCourses[0].holes[0].tees = ["White": 1]

        #expect(CourseIntegrity.usage(ofTeeNamed: "White", in: course) == .init(holesWithTeeBox: 1, comboTees: ["Blue/White"]))
        #expect(CourseIntegrity.usage(ofTeeNamed: "Blue", in: course) == .init(holesWithTeeBox: 0, comboTees: ["Blue/White"]))
        #expect(CourseIntegrity.usage(ofTeeNamed: "White", in: course).isInUse)

        course.comboTees = []
        course.subCourses[0].holes[0].tees = [:]
        #expect(!CourseIntegrity.usage(ofTeeNamed: "White", in: course).isInUse)
    }

    /// Blue and White tees, and a Blue/White combo tee where hole 1 plays from White.
    private func comboCourse() -> Course {
        var course = makeCourse(features: [])
        course.tees = [
            TeeDefinition(name: "Blue", color: "#0000FF"),
            TeeDefinition(name: "White", color: "#FFFFFF"),
        ]
        course.comboTees = [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "White"])]
        course.subCourses[0].comboTees = ["Blue/White": SubCourseTee(male: TeeInformation(rating: 35, slope: 125))]
        course.subCourses[0].holes[0].comboTees = ["Blue/White": "White"]
        return course
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

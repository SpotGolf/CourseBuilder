import Testing
@testable import CourseBuilder
import CourseDataSwift

struct CourseIntegrityTests {
    @Test func validationReportsMissingContentAndDanglingReferences() {
        let validFeature = Feature(id: 1, type: .tee, polygon: [])
        var course = makeCourse(features: [validFeature])
        course.subCourses[0].holes[0].features = [1, 99]
        course.subCourses[0].holes[0].yardages = ["Blue": 400, "White": 375]

        let warnings = CourseIntegrity.validateCourse(course)

        #expect(warnings.contains("Hole 1: missing green polygon"))
        #expect(warnings.contains("Hole 1: missing fairway polygon"))
        #expect(warnings.contains("Hole 1: missing centerline"))
        #expect(warnings.contains("Hole 1: references missing feature #99"))
        // Tee boxes are not tied to tee names, so yardages need no tee box.
        #expect(!warnings.contains { $0.contains("\"Blue\"") || $0.contains("\"White\"") })
    }

    @Test func repairRemovesOnlyDanglingReferences() {
        let tee = Feature(id: 1, type: .tee, polygon: [])
        var course = makeCourse(features: [tee])
        course.tees = [
            TeeDefinition(name: "Blue", color: "#0000FF"),
            TeeDefinition(name: "White", color: "#FFFFFF"),
        ]
        course.subCourses[0].holes[0].features = [1, 98, 99]
        course.subCourses[0].holes[0].yardages = ["Blue": 400, "White": 375]

        let report = CourseIntegrity.repairDanglingReferences(in: &course)

        #expect(report.removedFeatureReferences == 2)
        #expect(report.madeChanges)
        #expect(report.actions == [
            "Hole 1: removed missing feature reference #98",
            "Hole 1: removed missing feature reference #99",
        ])
        #expect(course.subCourses[0].holes[0].features == [1])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 400, "White": 375])
    }

    @Test func repairReportsNoChangesForValidReferences() {
        let tee = Feature(id: 1, type: .tee, polygon: [])
        var course = makeCourse(features: [tee])
        course.tees = [TeeDefinition(name: "Blue", color: "#0000FF")]
        course.subCourses[0].holes[0].features = [1]

        let report = CourseIntegrity.repairDanglingReferences(in: &course)

        #expect(!report.madeChanges)
        #expect(report.removedFeatureReferences == 0)
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

        let report = CourseIntegrity.cleanup(&course)

        #expect(report.removedYardages == 1)
        #expect(report.removedSubCourseTees == 1)
        #expect(course.subCourses[0].tees.keys.sorted() == ["Blue"])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 400])
    }

    @Test func renameTeeMigratesEveryTeeKey() {
        var course = makeCourse(features: [Feature(id: 1, type: .tee, polygon: [])])
        course.tees = [TeeDefinition(name: "Blue (Member)", color: "#0000FF")]
        course.subCourses[0].tees = ["Blue (Member)": SubCourseTee()]
        course.subCourses[0].holes[0].yardages = ["Blue (Member)": 390]

        let renamed = CourseIntegrity.renameTee(at: 0, to: "Blue", in: &course)

        #expect(renamed)
        #expect(course.tees[0].name == "Blue")
        #expect(course.subCourses[0].tees.keys.sorted() == ["Blue"])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 390])
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

        CourseIntegrity.removeTee(at: 0, from: &course)

        #expect(course.tees.isEmpty)
        #expect(course.subCourses[0].tees.isEmpty)
        #expect(course.subCourses[0].holes[0].yardages.isEmpty)
    }

    @Test func validationReportsComboTeeProblems() {
        var course = comboCourse()
        course.comboTees.append(ComboTeeDefinition(name: "Gold/Blue", tees: ["Gold", "Blue"]))
        course.subCourses[0].holes[0].comboTees = ["Blue/White": "White", "Gold/Blue": "Red", "Old": "Blue"]

        let warnings = CourseIntegrity.validateCourse(course)

        #expect(!warnings.contains { $0.contains("\"Blue/White\" plays from") })
        #expect(warnings.contains("Hole 1: combo tee \"Gold/Blue\" plays from \"Red\", which is not part of the combo"))
        #expect(warnings.contains("Hole 1: references undefined combo tee \"Old\""))
        #expect(warnings.contains("Combo tee \"Gold/Blue\" uses undefined tee \"Gold\""))

        course.subCourses[0].holes[0].comboTees = [:]
        #expect(CourseIntegrity.validateCourse(course).contains("Hole 1: combo tee \"Blue/White\" has no tee picked"))
    }

    @Test func validationAcceptsValidComboTee() {
        var course = comboCourse()

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

    @Test func usageListsComboTees() {
        var course = comboCourse()

        #expect(CourseIntegrity.usage(ofTeeNamed: "White", in: course) == .init(comboTees: ["Blue/White"]))
        #expect(CourseIntegrity.usage(ofTeeNamed: "Blue", in: course) == .init(comboTees: ["Blue/White"]))
        #expect(CourseIntegrity.usage(ofTeeNamed: "White", in: course).isInUse)

        course.comboTees = []
        #expect(!CourseIntegrity.usage(ofTeeNamed: "White", in: course).isInUse)
    }

    /// Blue and White tees, and a Blue/White combo tee where hole 1 plays from White.
    @Test func validationReportsMissingElevations() {
        var course = makeCourse(features: [Feature(id: 1, type: .green, polygon: [
            Coordinate(lat: 1, lon: 1),
            Coordinate(lat: 2, lon: 2, ele: 10),
        ])])

        #expect(CourseIntegrity.validateCourse(course).contains("2 point(s) are missing elevations. Cleanup looks them up."))

        course.location.coordinate.ele = 5
        course.features[0].polygon = [Coordinate(lat: 1, lon: 1, ele: 5), Coordinate(lat: 2, lon: 2, ele: 10)]

        #expect(!CourseIntegrity.validateCourse(course).contains { $0.contains("elevation") })
    }

    @Test func validationReportsMissingCenterlineFeature() {
        var course = makeCourse(features: [])
        course.subCourses[0].holes[0].centerline = 7

        let warnings = CourseIntegrity.validateCourse(course)

        #expect(warnings.contains("Hole 1: references missing centerline #7"))
        #expect(!warnings.contains("Hole 1: missing centerline"))
    }

    @Test func validationDoesNotReportCenterlineAsUnassigned() {
        var course = makeCourse(features: [])
        course.setCenterline([Coordinate(lat: 0, lon: 0), Coordinate(lat: 1, lon: 1)], subCourseIndex: 0, holeIndex: 0)

        let warnings = CourseIntegrity.validateCourse(course)

        #expect(!warnings.contains { $0.contains("unassigned") })
        #expect(!warnings.contains("Hole 1: missing centerline"))
    }

    @Test func cleanupRemovesMissingCenterlineReferenceAndUnusedCenterlines() {
        var course = makeCourse(features: [Feature(id: 5, type: .centerline, polygon: [Coordinate(lat: 0, lon: 0)])])
        course.subCourses[0].holes[0].centerline = 7

        let report = CourseIntegrity.cleanup(&course)

        #expect(course.subCourses[0].holes[0].centerline == nil)
        #expect(course.features.isEmpty)
        #expect(report.actions.contains("Hole 1: removed missing centerline reference #7"))
        #expect(report.actions.contains("Removed centerline #5 because no hole uses it"))
    }

    @Test func deletingCenterlineFeatureClearsAndRestoresHoleReference() throws {
        var course = makeCourse(features: [])
        course.setCenterline([Coordinate(lat: 0, lon: 0), Coordinate(lat: 1, lon: 1)], subCourseIndex: 0, holeIndex: 0)
        let id = try #require(course.subCourses[0].holes[0].centerline)

        let record = try #require(PolygonEditorOperations.deleteFeature(id: id, from: &course))
        #expect(course.subCourses[0].holes[0].centerline == nil)

        PolygonEditorOperations.restoreFeature(record, to: &course)
        #expect(course.subCourses[0].holes[0].centerline == id)
    }

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
                coordinate: Coordinate(lat: 0, lon: 0)
            ),
            features: features,
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
            ]
        )
    }
}

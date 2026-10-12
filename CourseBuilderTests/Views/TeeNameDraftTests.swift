import Testing
@testable import CourseBuilder
import CourseDataSwift

struct TeeNameDraftTests {
    @Test func draftCanBeClearedWithoutChangingCourse() {
        var course = makeCourse(teeNames: ["Blue", "White"])
        var draft = TeeNameDraft(name: "Blue")

        draft.text = ""

        #expect(draft.text == "")
        #expect(course.tees.map(\.name) == ["Blue", "White"])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 400, "White": 375])

        draft.text = "Bl"
        #expect(course.tees.map(\.name) == ["Blue", "White"])
    }

    @Test func commitRenamesTeeAndMigratesKeys() {
        var course = makeCourse(teeNames: ["Blue", "White"])
        var draft = TeeNameDraft(name: "Blue")
        draft.text = ""
        draft.text = "Black"

        let committed = draft.commit(at: 0, in: &course)

        #expect(committed)
        #expect(draft.text == "Black")
        #expect(course.tees.map(\.name) == ["Black", "White"])
        #expect(course.subCourses[0].holes[0].yardages == ["Black": 400, "White": 375])
    }

    @Test func commitEmptyNameRevertsDraftAndKeepsCourse() {
        var course = makeCourse(teeNames: ["Blue", "White"])
        var draft = TeeNameDraft(name: "Blue")
        draft.text = ""

        let committed = draft.commit(at: 0, in: &course)

        #expect(!committed)
        #expect(draft.text == "Blue")
        #expect(course.tees.map(\.name) == ["Blue", "White"])
        #expect(course.subCourses[0].holes[0].yardages == ["Blue": 400, "White": 375])
    }

    @Test func commitDuplicateNameRevertsDraftAndKeepsCourse() {
        var course = makeCourse(teeNames: ["Blue", "White"])
        var draft = TeeNameDraft(name: "White")
        draft.text = "Blue"

        let committed = draft.commit(at: 1, in: &course)

        #expect(!committed)
        #expect(draft.text == "White")
        #expect(course.tees.map(\.name) == ["Blue", "White"])
    }

    @Test func commitUnchangedNameSucceeds() {
        var course = makeCourse(teeNames: ["Blue", "White"])
        var draft = TeeNameDraft(name: "Blue")

        #expect(draft.commit(at: 0, in: &course))
        #expect(course.tees.map(\.name) == ["Blue", "White"])
    }

    @Test func commitOutOfRangeIndexClearsDraft() {
        var course = makeCourse(teeNames: ["Blue"])
        var draft = TeeNameDraft(name: "Blue")
        draft.text = "Black"

        #expect(!draft.commit(at: 5, in: &course))
        #expect(draft.text == "")
        #expect(course.tees.map(\.name) == ["Blue"])
    }

    private func makeCourse(teeNames: [String]) -> Course {
        var hole = Hole(number: 1, par: 4)
        hole.yardages = ["Blue": 400, "White": 375].filter { teeNames.contains($0.key) }
        var course = Course(
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Denver",
                state: "CO",
                country: "US",
                coordinate: Coordinate(latitude: 0, longitude: 0)
            ),
            features: [],
            subCourses: [SubCourse(name: "Front", holes: [hole])]
        )
        course.tees = teeNames.map { TeeDefinition(name: $0, color: "#FFFFFF") }
        return course
    }
}

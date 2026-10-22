import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("Centerline groups")
struct CenterlineGroupTests {
    @Test func removeGroupRenumbersLaterGroups() {
        var groups = [
            makeGroup(holes: 9, label: "9 holes (group 1)"),
            makeGroup(holes: 1, label: "1 holes (group 2)"),
            makeGroup(holes: 9, label: "9 holes (group 3)"),
        ]
        groups[2].assignedSubCourseIndex = 1

        groups.removeGroup(at: 1)

        #expect(groups.map(\.label) == ["9 holes (group 1)", "9 holes (group 2)"])
        #expect(groups.map(\.centerlines.count) == [9, 9])
        #expect(groups[1].assignedSubCourseIndex == 1)
    }

    @Test func relabelUsesHoleCounts() {
        var groups = [makeGroup(holes: 8, label: "9 holes (group 1)"), makeGroup(holes: 10, label: "9 holes (group 2)")]

        groups.relabel()

        #expect(groups.map(\.label) == ["8 holes (group 1)", "10 holes (group 2)"])
    }

    private func makeGroup(holes: Int, label: String) -> CenterlineGroup {
        CenterlineGroup(
            label: label,
            centerlines: (1...holes).map { OverpassAPIClient.ParsedCenterline(holeNumber: $0, coordinates: []) }
        )
    }
}

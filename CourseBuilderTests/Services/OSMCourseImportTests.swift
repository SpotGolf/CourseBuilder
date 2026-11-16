import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("OSM course import")
struct OSMCourseImportTests {
    /// A course with two 9-hole sub-courses and nothing drawn.
    private func makeCourse() -> Course {
        Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
            subCourses: [
                SubCourse(name: "Front", holes: (1...9).map { Hole(number: $0, par: 4) }),
                SubCourse(name: "Back", holes: (1...9).map { Hole(number: $0, par: 4) })
            ]
        )
    }

    /// Hole lines numbered `holes`, each running north from its own spot. `row` keeps groups apart.
    private func makeCenterlines(holes: ClosedRange<Int>, row: Int) -> [OverpassAPIClient.ParsedCenterline] {
        holes.map { number in
            let lon = -105.0 + Double(number) * 0.002
            let lat = 40.0 + Double(row) * 0.01
            return OverpassAPIClient.ParsedCenterline(
                holeNumber: number,
                coordinates: [Coordinate(lat: lat, lon: lon), Coordinate(lat: lat + 0.003, lon: lon)],
                osmID: "w\(row * 100 + number)"
            )
        }
    }

    @Test func numberedNinesStartAssigned() {
        let centerlines = makeCenterlines(holes: 1...18, row: 0)

        let groups = OSMCourseImport.centerlineGroups(from: centerlines, subCourseSizes: [9, 9])

        #expect(groups.map(\.centerlines.count) == [9, 9])
        #expect(groups.map(\.assignedSubCourseIndex) == [0, 1])
    }

    @Test func threeNinesNumberedOneToNineStartUnassigned() {
        let centerlines = (0..<3).flatMap { makeCenterlines(holes: 1...9, row: $0) }

        let groups = OSMCourseImport.centerlineGroups(from: centerlines, subCourseSizes: [9, 9, 9])

        #expect(groups.map(\.centerlines.count) == [9, 9, 9])
        // Only one group can be told to be the first nine. The user assigns the rest.
        #expect(groups.compactMap(\.assignedSubCourseIndex) == [0])
    }

    @Test func noHoleLinesGiveNoGroups() {
        #expect(OSMCourseImport.centerlineGroups(from: [], subCourseSizes: [9, 9]).isEmpty)
    }

    @Test func applyGivesEachGroupToItsSubCourse() {
        let first = makeCenterlines(holes: 1...9, row: 0)
        let second = makeCenterlines(holes: 1...9, row: 1)
        let result = OverpassAPIClient.ParsedResult(features: [], centerlines: first + second, courseBoundary: nil)
        // The first group in the list goes to the Back nine.
        let groups = [
            CenterlineGroup(label: "", centerlines: first, assignedSubCourseIndex: 1),
            CenterlineGroup(label: "", centerlines: second, assignedSubCourseIndex: 0)
        ]

        let imported = OSMCourseImport.apply(result, groups: groups, to: makeCourse())

        let course = imported.course
        let frontLine = course.features.first { $0.id == course.subCourses[0].holes[2].centerline }
        let backLine = course.features.first { $0.id == course.subCourses[1].holes[2].centerline }
        #expect(frontLine?.osmID == "w103")
        #expect(backLine?.osmID == "w3")
        #expect(course.subCourses.flatMap(\.holes).allSatisfy { $0.centerline != nil })
    }

    @Test func applyLeavesOutUnassignedGroups() {
        let first = makeCenterlines(holes: 1...9, row: 0)
        let other = makeCenterlines(holes: 1...9, row: 1)
        let result = OverpassAPIClient.ParsedResult(features: [], centerlines: first + other, courseBoundary: nil)
        let groups = [CenterlineGroup(label: "", centerlines: first, assignedSubCourseIndex: 0)]

        let course = OSMCourseImport.apply(result, groups: groups, to: makeCourse()).course

        #expect(course.subCourses[0].holes.allSatisfy { $0.centerline != nil })
        #expect(course.subCourses[1].holes.allSatisfy { $0.centerline == nil })
        #expect(!course.features.contains { $0.osmID?.hasPrefix("w10") == true })
    }

    @Test func applySetsTheCourseOSMIDAndRecordsWhatOSMHad() {
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [Coordinate(lat: 40.5, lon: -105.5), Coordinate(lat: 40.5001, lon: -105.5), Coordinate(lat: 40.5001, lon: -105.5001)],
            osmID: "w77",
            version: 4,
            tags: ["golf": "green"]
        )
        var result = OverpassAPIClient.ParsedResult(features: [green], centerlines: [], courseBoundary: nil)
        result.courseOSMID = "r42"

        let imported = OSMCourseImport.apply(result, groups: [], to: makeCourse())

        #expect(imported.course.osmID == "r42")
        #expect(imported.course.features.contains { $0.osmID == "w77" })
        #expect(imported.baseline.entries["w77"]?.version == 4)
        #expect(imported.baseline.checkedCourseElement)
    }

    @Test func applyLeavesTheCourseOSMIDUnsetWithoutAnOutline() {
        let result = OverpassAPIClient.ParsedResult(features: [], centerlines: [], courseBoundary: nil)

        #expect(OSMCourseImport.apply(result, groups: [], to: makeCourse()).course.osmID == nil)
    }
}

import Testing
@testable import CourseBuilder
import CourseDataSwift

struct CourseInfoUpdaterTests {
    @Test func scorecardDataComesFromFetchedCourse() {
        let existing = makeCourse(
            name: "Old Name",
            tees: [TeeDefinition(name: "Blue", color: "#123456")],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, maleHandicap: 3, yardages: ["Blue": 400])])]
        )
        let fetched = makeCourse(
            name: "New Name",
            tees: [TeeDefinition(name: "Black", color: "#000000"), TeeDefinition(name: "Blue", color: "#0000FF")],
            subCourses: [SubCourse(
                name: "Front",
                holes: [Hole(number: 1, par: 5, maleHandicap: 7, femaleHandicap: 9, yardages: ["Black": 520, "Blue": 500])],
                tees: ["Blue": SubCourseTee(male: TeeInformation(rating: 35.1, slope: 130))]
            )]
        )

        let merged = CourseInfoUpdater.merge(existing, with: fetched)

        #expect(merged.name == "New Name")
        #expect(merged.location.city == "Boulder")
        #expect(merged.tees == [TeeDefinition(name: "Black", color: "#000000"), TeeDefinition(name: "Blue", color: "#123456")])
        let hole = merged.subCourses[0].holes[0]
        #expect(hole.par == 5)
        #expect(hole.maleHandicap == 7)
        #expect(hole.femaleHandicap == 9)
        #expect(hole.yardages == ["Black": 520, "Blue": 500])
        #expect(merged.subCourses[0].tees["Blue"]?.male?.slope == 130)
    }

    @Test func mapWorkIsKept() {
        let centerline = [Coordinate(latitude: 1, longitude: 2, elevation: 3), Coordinate(latitude: 4, longitude: 5, elevation: 6)]
        var existing = makeCourse(
            name: "Course",
            tees: [TeeDefinition(name: "Blue", color: "#0000FF")],
            subCourses: [SubCourse(name: "Out", holes: [Hole(
                number: 1,
                par: 4,
                yardages: ["Blue": 400],
                features: [1, 2],
                tees: ["Blue": 1],
                centerline: centerline
            )])]
        )
        existing.features = [Feature(id: 1, type: .tee, polygon: []), Feature(id: 2, type: .green, polygon: [])]
        existing.location.coordinate = Coordinate(latitude: 40, longitude: -105)
        existing.golfCourseAPIIds = ["42"]
        let fetched = makeCourse(
            name: "Course",
            tees: [TeeDefinition(name: "Blue", color: "#0000FF")],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 5, yardages: ["Blue": 410])])]
        )

        let merged = CourseInfoUpdater.merge(existing, with: fetched)

        #expect(merged.id == existing.id)
        #expect(merged.features == existing.features)
        #expect(merged.location.coordinate == Coordinate(latitude: 40, longitude: -105))
        #expect(merged.golfCourseAPIIds == ["42"])
        #expect(merged.subCourses[0].id == existing.subCourses[0].id)
        #expect(merged.subCourses[0].name == "Out")
        let hole = merged.subCourses[0].holes[0]
        #expect(hole.features == [1, 2])
        #expect(hole.tees == ["Blue": 1])
        #expect(hole.centerline == centerline)
        #expect(hole.yardages == ["Blue": 410])
    }

    @Test func nothingIsRemovedAndNewSubCoursesAndHolesAreAdded() {
        let existing = makeCourse(
            name: "Course",
            tees: [TeeDefinition(name: "Blue", color: "#0000FF"), TeeDefinition(name: "Green", color: "#008000")],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, yardages: ["Blue": 400, "Green": 300])])]
        )
        let fetched = makeCourse(
            name: "Course",
            tees: [TeeDefinition(name: "Blue", color: "#0000FF")],
            subCourses: [
                SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, yardages: ["Blue": 401]), Hole(number: 2, par: 3, yardages: ["Blue": 180])]),
                SubCourse(name: "Back", holes: [Hole(number: 10, par: 5, yardages: ["Blue": 510])]),
            ]
        )

        let merged = CourseInfoUpdater.merge(existing, with: fetched)

        #expect(merged.tees.map(\.name) == ["Blue", "Green"])
        #expect(merged.subCourses.map(\.name) == ["Front", "Back"])
        #expect(merged.subCourses[0].holes.map(\.number) == [1, 2])
        #expect(merged.subCourses[0].holes[0].yardages == ["Blue": 401, "Green": 300])
    }

    @Test func newTeesGetYardagesButNoTeeBox() {
        let existing = makeCourse(
            name: "Course",
            tees: [TeeDefinition(name: "Blue", color: "#0000FF")],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, yardages: ["Blue": 390], tees: ["Blue": 2])])]
        )
        let fetched = makeCourse(
            name: "Course",
            tees: [TeeDefinition(name: "Blue", color: "#0000FF"), TeeDefinition(name: "Red", color: "#FF0000")],
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4, yardages: ["Blue": 390, "Red": 300])])]
        )

        let merged = CourseInfoUpdater.merge(existing, with: fetched)

        #expect(merged.subCourses[0].holes[0].yardages == ["Blue": 390, "Red": 300])
        #expect(merged.subCourses[0].holes[0].tees == ["Blue": 2])
    }

    private func makeCourse(name: String, tees: [TeeDefinition], subCourses: [SubCourse]) -> Course {
        Course(
            name: name,
            location: CourseLocation(
                address: "",
                city: "Boulder",
                state: "CO",
                country: "US",
                coordinate: Coordinate(latitude: 0, longitude: 0)
            ),
            tees: tees,
            subCourses: subCourses
        )
    }
}

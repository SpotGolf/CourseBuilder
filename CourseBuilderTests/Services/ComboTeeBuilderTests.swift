import Testing
@testable import CourseBuilder
import CourseDataSwift

struct ComboTeeBuilderTests {
    private typealias Position = ComboTeeBuilder.HolePosition

    @Test func componentsComeFromNamePieces() {
        let course = makeCourse(teeNames: ["Blue", "White", "Blue/White", "Gold"])

        #expect(ComboTeeBuilder.guessComponents(for: "Blue/White", in: course) == ["Blue", "White"])
        #expect(ComboTeeBuilder.guessComponents(for: "blue - white", in: course) == ["Blue", "White"])
        #expect(ComboTeeBuilder.guessComponents(for: "Blue & Red", in: course) == ["Blue"])
        #expect(ComboTeeBuilder.guessComponents(for: "Blue/Blue", in: course) == ["Blue"])
        #expect(ComboTeeBuilder.guessComponents(for: "Combo", in: course).isEmpty)
    }

    @Test func assignmentsMatchYardages() {
        var course = makeCourse(teeNames: ["Blue", "White", "Blue/White"])
        course.subCourses = [
            SubCourse(name: "Front", holes: [
                Hole(number: 1, par: 4, yardages: ["Blue": 410, "White": 385, "Blue/White": 410]),
                Hole(number: 2, par: 3, yardages: ["Blue": 180, "White": 165, "Blue/White": 165]),
                Hole(number: 3, par: 5, yardages: ["Blue": 520, "White": 500, "Blue/White": 510]),
            ]),
            SubCourse(name: "Back", holes: [
                Hole(number: 10, par: 4, yardages: ["Blue": 400, "White": 380, "Blue/White": 380]),
            ]),
        ]

        let assignments = ComboTeeBuilder.guessAssignments(for: "Blue/White", components: ["Blue", "White"], in: course)

        #expect(assignments == [
            Position(subCourseIndex: 0, holeIndex: 0): "Blue",
            Position(subCourseIndex: 0, holeIndex: 1): "White",
            Position(subCourseIndex: 1, holeIndex: 0): "White",
        ])
    }

    @Test func convertMovesTeeToComboTee() {
        var course = makeCourse(teeNames: ["Blue", "White", "Blue/White"])
        course.subCourses = [
            SubCourse(
                name: "Front",
                holes: [
                    Hole(number: 1, par: 4, yardages: ["Blue": 410, "White": 385, "Blue/White": 410], tees: ["Blue": 1, "White": 2, "Blue/White": 1]),
                    Hole(number: 2, par: 3, yardages: ["Blue": 180, "White": 165, "Blue/White": 165]),
                ],
                tees: [
                    "Blue": SubCourseTee(male: TeeInformation(rating: 36, slope: 130)),
                    "Blue/White": SubCourseTee(male: TeeInformation(rating: 35, slope: 125)),
                ]
            )
        ]

        ComboTeeBuilder.convert(
            teeNamed: "Blue/White",
            components: ["Blue", "White"],
            assignments: [Position(subCourseIndex: 0, holeIndex: 0): "Blue", Position(subCourseIndex: 0, holeIndex: 1): "White"],
            in: &course
        )

        #expect(course.tees.map(\.name) == ["Blue", "White"])
        #expect(course.comboTees == [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "White"])])
        let subCourse = course.subCourses[0]
        #expect(subCourse.tees.keys.sorted() == ["Blue"])
        #expect(subCourse.comboTees["Blue/White"]?.male?.slope == 125)
        #expect(subCourse.holes[0].yardages == ["Blue": 410, "White": 385])
        #expect(subCourse.holes[0].tees == ["Blue": 1, "White": 2])
        #expect(subCourse.holes[0].comboTees == ["Blue/White": "Blue"])
        #expect(subCourse.holes[1].comboTees == ["Blue/White": "White"])
    }

    @Test func updateChangesComponentsAndHoles() {
        var course = comboCourse()

        let assignments = ComboTeeBuilder.assignments(forComboNamed: "Blue/White", in: course)
        #expect(assignments == [Position(subCourseIndex: 0, holeIndex: 0): "Blue", Position(subCourseIndex: 0, holeIndex: 1): "White"])

        ComboTeeBuilder.update(
            comboNamed: "Blue/White",
            components: ["Blue", "Gold"],
            assignments: [Position(subCourseIndex: 0, holeIndex: 0): "Gold", Position(subCourseIndex: 0, holeIndex: 1): "Blue"],
            in: &course
        )

        #expect(course.comboTees == [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "Gold"])])
        #expect(course.subCourses[0].holes[0].comboTees == ["Blue/White": "Gold"])
        #expect(course.subCourses[0].holes[1].comboTees == ["Blue/White": "Blue"])
        #expect(course.subCourses[0].comboTees["Blue/White"]?.male?.slope == 125)
    }

    @Test func deleteRemovesEveryComboTeeKey() {
        var course = comboCourse()

        ComboTeeBuilder.delete(comboNamed: "Blue/White", from: &course)

        #expect(course.comboTees.isEmpty)
        #expect(course.subCourses[0].comboTees.isEmpty)
        #expect(course.subCourses[0].holes.allSatisfy { $0.comboTees.isEmpty })
        #expect(course.tees.map(\.name) == ["Blue", "White", "Gold"])
    }

    private func comboCourse() -> Course {
        var course = makeCourse(teeNames: ["Blue", "White", "Gold"])
        course.comboTees = [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "White"])]
        course.subCourses = [
            SubCourse(
                name: "Front",
                holes: [
                    Hole(number: 1, par: 4, comboTees: ["Blue/White": "Blue"]),
                    Hole(number: 2, par: 3, comboTees: ["Blue/White": "White"]),
                ],
                comboTees: ["Blue/White": SubCourseTee(male: TeeInformation(rating: 35, slope: 125))]
            )
        ]
        return course
    }

    private func makeCourse(teeNames: [String]) -> Course {
        Course(
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Boulder",
                state: "CO",
                country: "US",
                coordinate: Coordinate(latitude: 0, longitude: 0)
            ),
            tees: teeNames.map { TeeDefinition(name: $0, color: TeeDefinition.defaultColor(for: $0)) }
        )
    }
}

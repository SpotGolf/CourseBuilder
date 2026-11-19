import Testing
@testable import CourseBuilder
import CourseDataSwift

struct ScorecardRoundsTests {
    /// A course with a "Blue" tee and one nine per name. Each nine is given by its male rating
    /// and slope, or `nil` for none.
    private func makeCourse(_ nines: [(name: String, rating: Double?, slope: Int?)], handicaps: [[Int]] = []) -> Course {
        let subCourses = nines.enumerated().map { index, nine in
            SubCourse(
                name: nine.name,
                holes: (1...9).map { number in
                    Hole(number: number, par: 4, maleHandicap: handicaps.indices.contains(index) ? handicaps[index][number - 1] : 0)
                },
                tees: ["Blue": SubCourseTee(male: TeeInformation(rating: nine.rating, slope: nine.slope, totalYards: 3000, parTotal: 36))]
            )
        }
        return Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "", coordinate: Coordinate(lat: 0, lon: 0)),
            tees: [TeeDefinition(name: "Blue", color: "#0000FF")],
            subCourses: subCourses
        )
    }

    private func ratings(_ course: Course) -> [Double?] {
        course.subCourses.map { $0.tees["Blue"]?.male?.rating }
    }

    private func slopes(_ course: Course) -> [Int?] {
        course.subCourses.map { $0.tees["Blue"]?.male?.slope }
    }

    private func isClose(_ values: [Double?], _ expected: [Double]) -> Bool {
        values.count == expected.count && zip(values, expected).allSatisfy { value, expected in
            value.map { abs($0 - expected) < 1e-9 } ?? false
        }
    }

    // MARK: - Rounds

    @Test func roundsDependOnTheNumberOfSubCourses() {
        let nine: (name: String, rating: Double?, slope: Int?) = ("Nine", nil, nil)

        #expect(ScorecardRounds.rounds(in: makeCourse([])).isEmpty)
        #expect(ScorecardRounds.rounds(in: makeCourse([nine])) == [[0]])
        #expect(ScorecardRounds.rounds(in: makeCourse([nine, nine])) == [[0, 1]])
        #expect(ScorecardRounds.rounds(in: makeCourse([nine, nine, nine])) == [[0, 1], [1, 2], [0, 2]])
        #expect(ScorecardRounds.rounds(in: makeCourse([nine, nine, nine, nine])) == [[0], [1], [2], [3]])
    }

    @Test func roundIsNamedAfterItsSubCourses() {
        let course = makeCourse([("Vista", nil, nil), ("Canyon", nil, nil), ("Sunshine", nil, nil)])

        #expect(ScorecardRounds.name(of: [1, 2], in: course) == "Canyon + Sunshine")
        #expect(ScorecardRounds.name(of: [0], in: course) == "Vista")
    }

    // MARK: - Two sub-courses

    @Test func twoSubCoursesShowTheScorecardValues() {
        let course = makeCourse([("Front", 36.75, 137), ("Back", 36.75, 137)])

        #expect(ScorecardRounds.rating(in: course, round: [0, 1], tee: "Blue", gender: .male) == 73.5)
        #expect(ScorecardRounds.slope(in: course, round: [0, 1], tee: "Blue", gender: .male) == 137)
        #expect(ScorecardRounds.rating(in: course, round: [0, 1], tee: "Blue", gender: .female) == nil)
    }

    @Test func twoSubCoursesStoreHalfTheRatingAndTheWholeSlope() {
        var course = makeCourse([("Front", 36.0, 120), ("Back", 37.0, 130)])

        ScorecardRounds.setRating(71.3, in: &course, round: [0, 1], tee: "Blue", gender: .male)
        ScorecardRounds.setSlope(128, in: &course, round: [0, 1], tee: "Blue", gender: .male)

        #expect(ratings(course) == [35.65, 35.65])
        #expect(slopes(course) == [128, 128])
        #expect(ScorecardRounds.rating(in: course, round: [0, 1], tee: "Blue", gender: .male) == 71.3)
        // Yards and par are kept.
        #expect(course.subCourses[0].tees["Blue"]?.male?.totalYards == 3000)
    }

    @Test func newGenderIsAddedAndClearingRemovesTheValues() {
        var course = makeCourse([("Front", 36.0, 120), ("Back", 37.0, 130)])

        ScorecardRounds.setRating(nil, in: &course, round: [0, 1], tee: "Blue", gender: .female)
        #expect(course.subCourses[0].tees["Blue"]?.female == nil)

        ScorecardRounds.setRating(75.0, in: &course, round: [0, 1], tee: "Blue", gender: .female)
        #expect(course.subCourses.map { $0.tees["Blue"]?.female?.rating } == [37.5, 37.5])

        ScorecardRounds.setRating(nil, in: &course, round: [0, 1], tee: "Blue", gender: .male)
        #expect(ratings(course) == [nil, nil])
        #expect(slopes(course) == [120, 130])
    }

    @Test func comboTeeValuesAreStoredWithTheComboTees() {
        var course = makeCourse([("Front", 36.0, 120), ("Back", 37.0, 130)])
        course.comboTees = [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "White"])]

        ScorecardRounds.setRating(70.0, in: &course, round: [0, 1], tee: "Blue/White", gender: .male)

        #expect(course.subCourses.map { $0.comboTees["Blue/White"]?.male?.rating } == [35.0, 35.0])
        #expect(course.subCourses[0].tees["Blue/White"] == nil)
        #expect(ScorecardRounds.rating(in: course, round: [0, 1], tee: "Blue/White", gender: .male) == 70.0)
    }

    // MARK: - Three sub-courses

    /// Vista + Canyon is 71.2 / 125, Canyon + Sunshine is 73.3 / 135, and Vista + Sunshine is
    /// 72.1 / 130.
    private func threeNines() -> Course {
        makeCourse([("Vista", 35.0, 120), ("Canyon", 36.2, 130), ("Sunshine", 37.1, 140)])
    }

    @Test func threeSubCoursesShowEachPair() {
        let course = threeNines()

        let shown = ScorecardRounds.rounds(in: course).map {
            ScorecardRounds.rating(in: course, round: $0, tee: "Blue", gender: .male)
        }
        #expect(shown == [71.2, 73.3, 72.1])
        #expect(ScorecardRounds.rounds(in: course).map {
            ScorecardRounds.slope(in: course, round: $0, tee: "Blue", gender: .male)
        } == [125, 135, 130])
    }

    @Test func changingOnePairKeepsTheOtherTwo() {
        var course = threeNines()

        ScorecardRounds.setRating(72.0, in: &course, round: [0, 1], tee: "Blue", gender: .male)
        ScorecardRounds.setSlope(127, in: &course, round: [0, 1], tee: "Blue", gender: .male)

        // Vista and Canyon each go up, and Sunshine comes down by the same amount.
        #expect(isClose(ratings(course), [35.4, 36.6, 36.7]))
        #expect(slopes(course) == [122, 132, 138])
        #expect(ScorecardRounds.rounds(in: course).map {
            ScorecardRounds.rating(in: course, round: $0, tee: "Blue", gender: .male)
        } == [72.0, 73.3, 72.1])
        #expect(ScorecardRounds.rounds(in: course).map {
            ScorecardRounds.slope(in: course, round: $0, tee: "Blue", gender: .male)
        } == [127, 135, 130])
    }

    @Test func pairsCanBeTypedInOneAtATime() {
        var course = makeCourse([("Vista", nil, nil), ("Canyon", nil, nil), ("Sunshine", nil, nil)])
        let pairs: [(round: [Int], rating: Double, slope: Int)] = [([0, 1], 71.2, 125), ([1, 2], 73.3, 135), ([0, 2], 72.1, 130)]

        for pair in pairs {
            ScorecardRounds.setRating(pair.rating, in: &course, round: pair.round, tee: "Blue", gender: .male)
            ScorecardRounds.setSlope(pair.slope, in: &course, round: pair.round, tee: "Blue", gender: .male)
            // The pair shows what was typed.
            #expect(ScorecardRounds.rating(in: course, round: pair.round, tee: "Blue", gender: .male) == pair.rating)
            #expect(ScorecardRounds.slope(in: course, round: pair.round, tee: "Blue", gender: .male) == pair.slope)
        }

        #expect(isClose(ratings(course), [35.0, 36.2, 37.1]))
        #expect(slopes(course) == [120, 130, 140])
    }

    @Test func oddSlopeSumStillShowsTheTypedSlope() {
        // Sunshine has no slope, so Vista and Canyon share the change. Their slopes cannot both
        // move by half a point.
        var course = makeCourse([("Vista", 35.0, 120), ("Canyon", 36.2, 131), ("Sunshine", 37.1, nil)])

        ScorecardRounds.setSlope(128, in: &course, round: [0, 1], tee: "Blue", gender: .male)

        #expect(slopes(course)[0]! + slopes(course)[1]! == 256)
        #expect(ScorecardRounds.slope(in: course, round: [0, 1], tee: "Blue", gender: .male) == 128)
    }

    @Test func clearingAPairOfThreeDoesNothing() {
        var course = threeNines()

        ScorecardRounds.setRating(nil, in: &course, round: [0, 1], tee: "Blue", gender: .male)
        ScorecardRounds.setSlope(nil, in: &course, round: [0, 1], tee: "Blue", gender: .male)

        #expect(ratings(course) == [35.0, 36.2, 37.1])
        #expect(slopes(course) == [120, 130, 140])
    }

    // MARK: - Sub-courses alone

    @Test func subCourseAloneStoresValuesAsTyped() {
        var course = makeCourse([("A", 36.75, 120), ("B", 36.0, 121), ("C", 36.0, 122), ("D", 36.0, 123)])

        #expect(ScorecardRounds.rating(in: course, round: [0], tee: "Blue", gender: .male) == 36.75)

        ScorecardRounds.setRating(35.25, in: &course, round: [3], tee: "Blue", gender: .male)
        ScorecardRounds.setSlope(nil, in: &course, round: [3], tee: "Blue", gender: .male)

        #expect(ratings(course) == [36.75, 36.0, 36.0, 35.25])
        #expect(slopes(course) == [120, 121, 122, nil])
    }

    // MARK: - Handicaps

    @Test func handicapsShowOddsForTheFirstNineAndEvensForTheSecond() {
        let ranks = [3, 1, 2, 9, 8, 7, 6, 5, 4]
        let course = makeCourse(
            [("Vista", nil, nil), ("Canyon", nil, nil), ("Sunshine", nil, nil)],
            handicaps: [ranks, ranks, ranks]
        )

        #expect(ScorecardRounds.handicaps(in: course, round: [0, 1], subCourse: 0, gender: .male) == [5, 1, 3, 17, 15, 13, 11, 9, 7])
        #expect(ScorecardRounds.handicaps(in: course, round: [0, 1], subCourse: 1, gender: .male) == [6, 2, 4, 18, 16, 14, 12, 10, 8])
        // Sunshine is not in the round, and no round shows the stored values.
        #expect(ScorecardRounds.handicaps(in: course, round: [0, 1], subCourse: 2, gender: .male) == ranks)
        #expect(ScorecardRounds.handicaps(in: course, round: nil, subCourse: 0, gender: .male) == ranks)
        #expect(ScorecardRounds.handicaps(in: course, round: [0, 1], subCourse: 0, gender: .female) == Array(repeating: 0, count: 9))
    }

    @Test func handicapsStoredAsPrintedAreRankedFirst() {
        // An older import stored a back nine's even numbers.
        let printed = [6, 2, 4, 18, 16, 14, 12, 10, 8]
        var course = makeCourse(
            [("Vista", nil, nil), ("Canyon", nil, nil), ("Sunshine", nil, nil)],
            handicaps: [printed, printed, printed]
        )

        #expect(ScorecardRounds.handicaps(in: course, round: [0, 2], subCourse: 0, gender: .male) == [5, 1, 3, 17, 15, 13, 11, 9, 7])

        ScorecardRounds.setHandicap(1, in: &course, round: [0, 2], subCourse: 0, hole: 0, gender: .male)

        #expect(course.subCourses[0].holes.map(\.maleHandicap) == [1, 1, 2, 9, 8, 7, 6, 5, 4])
        #expect(course.subCourses[1].holes.map(\.maleHandicap) == printed)
    }

    @Test func typedHandicapIsStoredAsARankAndDoesNotMoveOtherHoles() {
        let ranks = [3, 1, 2, 9, 8, 7, 6, 5, 4]
        var course = makeCourse(
            [("Vista", nil, nil), ("Canyon", nil, nil), ("Sunshine", nil, nil)],
            handicaps: [ranks, ranks, ranks]
        )

        // Canyon is played second, so 18 is its ninth rank.
        ScorecardRounds.setHandicap(18, in: &course, round: [0, 1], subCourse: 1, hole: 0, gender: .male)

        #expect(course.subCourses[1].holes.map(\.maleHandicap) == [9, 1, 2, 9, 8, 7, 6, 5, 4])
        #expect(ScorecardRounds.handicaps(in: course, round: [0, 1], subCourse: 1, gender: .male) == [18, 2, 4, 18, 16, 14, 12, 10, 8])

        ScorecardRounds.setHandicap(0, in: &course, round: [0, 1], subCourse: 1, hole: 3, gender: .male)
        #expect(course.subCourses[1].holes[3].maleHandicap == 0)

        // With no round, the handicap is stored as typed.
        ScorecardRounds.setHandicap(7, in: &course, round: nil, subCourse: 2, hole: 0, gender: .female)
        #expect(course.subCourses[2].holes[0].femaleHandicap == 7)
    }
}

import Foundation
import CourseDataSwift

/// Reads and changes a course's ratings, slopes, and handicaps as a scorecard prints them.
///
/// A course stores these values for each sub-course, but a scorecard prints them for a round. A
/// round is a list of zero-based indices into ``Course/subCourses``, in the order played. Values
/// are converted on the way in and out, so the user can check them against the scorecard and type
/// in what it says.
enum ScorecardRounds {
    // MARK: - Rounds

    /// The rounds a scorecard prints for the course.
    ///
    /// - One sub-course: the sub-course alone.
    /// - Two sub-courses: both together, such as a front and back nine.
    /// - Three sub-courses: each pair, such as "Vista + Canyon".
    /// - Four or more: each sub-course alone, since nothing says which are played together.
    static func rounds(in course: Course) -> [[Int]] {
        switch course.subCourses.count {
        case 2: [[0, 1]]
        case 3: [[0, 1], [1, 2], [0, 2]]
        default: course.subCourses.indices.map { [$0] }
        }
    }

    /// The names of a round's sub-courses, joined with " + ".
    static func name(of round: [Int], in course: Course) -> String {
        round.map { course.subCourses[$0].name }.joined(separator: " + ")
    }

    // MARK: - Rating and slope

    /// The rating of a round from one tee, as the scorecard prints it. A sub-course alone gives
    /// its stored rating. `nil` when any of the round's sub-courses has no rating.
    static func rating(in course: Course, round: [Int], tee: String, gender: Gender) -> Double? {
        if round.count == 1 {
            return information(in: course, subCourse: round[0], tee: tee, gender: gender)?.rating
        }
        return course.teeInformation(subCourseIndices: round, tee: tee, gender: gender)?.rating
    }

    /// The slope of a round from one tee, as the scorecard prints it. `nil` when any of the
    /// round's sub-courses has no slope.
    static func slope(in course: Course, round: [Int], tee: String, gender: Gender) -> Int? {
        if round.count == 1 {
            return information(in: course, subCourse: round[0], tee: tee, gender: gender)?.slope
        }
        return course.teeInformation(subCourseIndices: round, tee: tee, gender: gender)?.slope
    }

    /// Stores the rating a scorecard prints for a round.
    ///
    /// - A sub-course alone stores the rating as given.
    /// - With two sub-courses, each stores half.
    /// - With three sub-courses, the three are worked out again from the ratings of the three
    ///   pairs, so the other two pairs keep the ratings they show. Until all three sub-courses
    ///   have a rating, the rating is shared between the round's two sub-courses instead: a
    ///   sub-course that has a rating keeps it and the other takes the rest.
    ///
    /// A `nil` rating clears the round's sub-courses. With three sub-courses it does nothing,
    /// since clearing two of them would also clear the other pairs.
    static func setRating(_ rating: Double?, in course: inout Course, round: [Int], tee: String, gender: Gender) {
        let stored = course.subCourses.indices.map {
            information(in: course, subCourse: $0, tee: tee, gender: gender)?.rating
        }
        let shown = rounds(in: course).map { self.rating(in: course, round: $0, tee: tee, gender: gender) }
        guard let parts = parts(total: rating, in: course, round: round, stored: stored, shownTotals: shown) else { return }
        for (subCourse, part) in parts {
            update(&course, subCourse: subCourse, tee: tee, gender: gender, isClearing: part == nil) { $0.rating = part }
        }
    }

    /// Stores the slope a scorecard prints for a round.
    ///
    /// This works as ``setRating(_:in:round:tee:gender:)`` does, except that a round's slope is the
    /// average of its sub-courses' slopes. With two sub-courses, each stores the slope as given.
    static func setSlope(_ slope: Int?, in course: inout Course, round: [Int], tee: String, gender: Gender) {
        // A round's slope is an average, so the sub-courses' slopes add up to the slope times the
        // number of sub-courses.
        let count = Double(round.count)
        let stored = course.subCourses.indices.map {
            information(in: course, subCourse: $0, tee: tee, gender: gender)?.slope.map(Double.init)
        }
        let shown = rounds(in: course).map { round in
            self.slope(in: course, round: round, tee: tee, gender: gender).map { Double($0) * Double(round.count) }
        }
        guard var parts = parts(total: slope.map { Double($0) * count }, in: course, round: round, stored: stored, shownTotals: shown) else { return }

        // Slopes are whole numbers. When a round's two parts are not, round the first and give
        // the second the rest, so the round still shows the slope that was typed.
        if let slope, round.count == 2, let first = parts[round[0]] ?? nil, first != first.rounded() {
            parts[round[0]] = first.rounded()
            parts[round[1]] = Double(slope) * count - first.rounded()
        }
        for (subCourse, part) in parts {
            update(&course, subCourse: subCourse, tee: tee, gender: gender, isClearing: part == nil) {
                $0.slope = part.map { Int($0.rounded()) }
            }
        }
    }

    /// The new value of each sub-course that changes when a round's total becomes `total`, or
    /// `nil` when nothing changes.
    ///
    /// - Parameters:
    ///   - stored: Each sub-course's current value.
    ///   - shownTotals: The total of each of the course's rounds, in the order of ``rounds(in:)``.
    private static func parts(
        total: Double?,
        in course: Course,
        round: [Int],
        stored: [Double?],
        shownTotals: [Double?]
    ) -> [Int: Double?]? {
        guard round.allSatisfy(course.subCourses.indices.contains) else { return nil }
        if round.count == 1 {
            return [round[0]: total]
        }
        guard round.count == 2 else { return nil }
        let first = round[0]
        let second = round[1]

        if course.subCourses.count == 2 {
            return [first: total.map { $0 / 2 }, second: total.map { $0 / 2 }]
        }
        guard let total else { return nil }

        let allRounds = rounds(in: course)
        let totals = shownTotals.compactMap { $0 }
        if course.subCourses.count == 3, totals.count == allRounds.count {
            // Each sub-course is half of the two pairs it is in, less the pair it is not in.
            var parts: [Int: Double?] = [:]
            for subCourse in course.subCourses.indices {
                var sum = 0.0
                for (index, pair) in allRounds.enumerated() {
                    let pairTotal = Set(pair) == Set(round) ? total : totals[index]
                    sum += pair.contains(subCourse) ? pairTotal : -pairTotal
                }
                parts[subCourse] = sum / 2
            }
            return parts
        }

        switch (stored[first], stored[second]) {
        case (nil, nil):
            return [first: total / 2, second: total / 2]
        case (let kept?, nil):
            return [second: total - kept]
        case (nil, let kept?):
            return [first: total - kept]
        case (let firstValue?, let secondValue?):
            let change = (total - firstValue - secondValue) / 2
            return [first: firstValue + change, second: secondValue + change]
        }
    }

    private static func information(in course: Course, subCourse: Int, tee: String, gender: Gender) -> TeeInformation? {
        guard course.subCourses.indices.contains(subCourse) else { return nil }
        let subCourse = course.subCourses[subCourse]
        return (subCourse.tees[tee] ?? subCourse.comboTees[tee])?.information(for: gender)
    }

    /// Changes one sub-course's values for a tee and gender, adding them when the sub-course has
    /// none. Nothing is added when `isClearing` is `true`.
    private static func update(
        _ course: inout Course,
        subCourse: Int,
        tee: String,
        gender: Gender,
        isClearing: Bool,
        change: (inout TeeInformation) -> Void
    ) {
        let isComboTee = course.subCourses[subCourse].tees[tee] == nil
            && (course.subCourses[subCourse].comboTees[tee] != nil || course.comboTees.contains { $0.name == tee })
        let existing = isComboTee ? course.subCourses[subCourse].comboTees[tee] : course.subCourses[subCourse].tees[tee]
        guard !isClearing || existing?.information(for: gender) != nil else { return }

        var subCourseTee = existing ?? SubCourseTee()
        var information = subCourseTee.information(for: gender) ?? TeeInformation()
        change(&information)
        switch gender {
        case .male: subCourseTee.male = information
        case .female: subCourseTee.female = information
        }
        if isComboTee {
            course.subCourses[subCourse].comboTees[tee] = subCourseTee
        } else {
            course.subCourses[subCourse].tees[tee] = subCourseTee
        }
    }

    // MARK: - Handicaps

    /// The handicaps of one sub-course's holes, in hole order, as the scorecard prints them for a
    /// round. A hole with no handicap gives 0.
    ///
    /// In a round of two sub-courses, the first gets the odd numbers and the second gets the even
    /// numbers, in the order of each hole's rank in its own sub-course. When `round` is `nil` or
    /// does not have the sub-course, the stored handicaps are given.
    static func handicaps(in course: Course, round: [Int]?, subCourse: Int, gender: Gender) -> [Int] {
        let stored = course.subCourses[subCourse].holes.map { gender == .male ? $0.maleHandicap : $0.femaleHandicap }
        guard let round, round.count > 1, let position = round.firstIndex(of: subCourse) else { return stored }
        return ranks(stored).map { $0 == 0 ? 0 : ($0 - 1) * round.count + position + 1 }
    }

    /// Stores the handicap a scorecard prints for a hole in a round, as the hole's rank in its
    /// own sub-course. The sub-course's other holes are stored as ranks too, if they are not yet.
    ///
    /// When `round` is `nil` or does not have the sub-course, the handicap is stored as given.
    ///
    /// - Parameter hole: The zero-based index of the hole in the sub-course.
    static func setHandicap(_ handicap: Int, in course: inout Course, round: [Int]?, subCourse: Int, hole: Int, gender: Gender) {
        let stored = course.subCourses[subCourse].holes.map { gender == .male ? $0.maleHandicap : $0.femaleHandicap }
        var values = stored
        if let round, round.count > 1, let position = round.firstIndex(of: subCourse) {
            values = ranks(stored)
            values[hole] = handicap <= 0 ? 0 : max(0, handicap - position - 1) / round.count + 1
        } else {
            values[hole] = handicap
        }
        for index in values.indices {
            switch gender {
            case .male: course.subCourses[subCourse].holes[index].maleHandicap = values[index]
            case .female: course.subCourses[subCourse].holes[index].femaleHandicap = values[index]
            }
        }
    }

    /// Each handicap's rank among `handicaps`, where 1 is the lowest. A missing handicap (0)
    /// stays 0. Handicaps that are already no higher than the number of holes are returned
    /// unchanged, so that a rank typed twice does not move the other holes while it is corrected.
    private static func ranks(_ handicaps: [Int]) -> [Int] {
        guard handicaps.contains(where: { $0 > handicaps.count }) else { return handicaps }
        return handicaps.indices.map { hole in
            guard handicaps[hole] > 0 else { return 0 }
            return 1 + handicaps.indices.count { other in
                handicaps[other] > 0
                    && (handicaps[other] < handicaps[hole] || (handicaps[other] == handicaps[hole] && other < hole))
            }
        }
    }
}

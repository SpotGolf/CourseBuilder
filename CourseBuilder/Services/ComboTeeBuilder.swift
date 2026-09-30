import Foundation
import CourseDataSwift

/// Turns a regular tee into a combo tee that plays from one of two other tees on each hole.
enum ComboTeeBuilder {
    /// The position of a hole in the course.
    struct HolePosition: Hashable {
        let subCourseIndex: Int
        let holeIndex: Int
    }

    /// Guesses the tees that make up a combo tee from its name. The name is split on
    /// non-alphanumeric characters and each piece that names another tee is returned, in order.
    /// For example, "Blue/White" returns ["Blue", "White"] when the course has both tees.
    static func guessComponents(for teeName: String, in course: Course) -> [String] {
        let pieces = teeName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var components: [String] = []
        for piece in pieces {
            guard let tee = course.tees.first(where: {
                $0.name != teeName && $0.name.caseInsensitiveCompare(piece) == .orderedSame
            }), !components.contains(tee.name) else { continue }
            components.append(tee.name)
        }
        return components
    }

    /// Guesses which component tee each hole plays from by finding the component whose yardage
    /// matches the combo tee's yardage. Holes with no match are left out.
    static func guessAssignments(for teeName: String, components: [String], in course: Course) -> [HolePosition: String] {
        var assignments: [HolePosition: String] = [:]
        for (subCourseIndex, subCourse) in course.subCourses.enumerated() {
            for (holeIndex, hole) in subCourse.holes.enumerated() {
                guard let yardage = hole.yardages[teeName],
                      let match = components.first(where: { hole.yardages[$0] == yardage }) else { continue }
                assignments[HolePosition(subCourseIndex: subCourseIndex, holeIndex: holeIndex)] = match
            }
        }
        return assignments
    }

    /// Returns the tee each hole plays from for an existing combo tee.
    static func assignments(forComboNamed comboName: String, in course: Course) -> [HolePosition: String] {
        var assignments: [HolePosition: String] = [:]
        for (subCourseIndex, subCourse) in course.subCourses.enumerated() {
            for (holeIndex, hole) in subCourse.holes.enumerated() {
                guard let tee = hole.comboTees[comboName] else { continue }
                assignments[HolePosition(subCourseIndex: subCourseIndex, holeIndex: holeIndex)] = tee
            }
        }
        return assignments
    }

    /// Replaces the tee with a combo tee made of `components`. Each hole plays from the tee in
    /// `assignments`. The tee's ratings and slopes move to the sub-course combo tees. Its yardages
    /// and tee box assignments are removed, since the combo tee uses those of its component tees.
    static func convert(
        teeNamed teeName: String,
        components: [String],
        assignments: [HolePosition: String],
        in course: inout Course
    ) {
        course.tees.removeAll { $0.name == teeName }
        for subCourseIndex in course.subCourses.indices {
            if let info = course.subCourses[subCourseIndex].tees.removeValue(forKey: teeName) {
                course.subCourses[subCourseIndex].comboTees[teeName] = info
            }
            for holeIndex in course.subCourses[subCourseIndex].holes.indices {
                course.subCourses[subCourseIndex].holes[holeIndex].yardages.removeValue(forKey: teeName)
                course.subCourses[subCourseIndex].holes[holeIndex].tees.removeValue(forKey: teeName)
            }
        }
        update(comboNamed: teeName, components: components, assignments: assignments, in: &course)
    }

    /// Sets the tees that make up the combo tee and the tee each hole plays from. Adds the combo
    /// tee if the course does not have it yet.
    static func update(
        comboNamed comboName: String,
        components: [String],
        assignments: [HolePosition: String],
        in course: inout Course
    ) {
        if let index = course.comboTees.firstIndex(where: { $0.name == comboName }) {
            course.comboTees[index].tees = components
        } else {
            course.comboTees.append(ComboTeeDefinition(name: comboName, tees: components))
        }
        for subCourseIndex in course.subCourses.indices {
            for holeIndex in course.subCourses[subCourseIndex].holes.indices {
                let position = HolePosition(subCourseIndex: subCourseIndex, holeIndex: holeIndex)
                course.subCourses[subCourseIndex].holes[holeIndex].comboTees[comboName] = assignments[position]
            }
        }
    }

    /// Removes the combo tee, its ratings and slopes, and the tee each hole plays from.
    static func delete(comboNamed comboName: String, from course: inout Course) {
        course.comboTees.removeAll { $0.name == comboName }
        for subCourseIndex in course.subCourses.indices {
            course.subCourses[subCourseIndex].comboTees.removeValue(forKey: comboName)
            for holeIndex in course.subCourses[subCourseIndex].holes.indices {
                course.subCourses[subCourseIndex].holes[holeIndex].comboTees.removeValue(forKey: comboName)
            }
        }
    }
}

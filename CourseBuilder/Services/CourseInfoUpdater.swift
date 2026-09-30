import Foundation
import CourseDataSwift

/// Updates a course's scorecard data with a fresh copy from GolfCourseAPI.
///
/// The fetched course wins for names, address, tee list, ratings, slopes, par, handicaps, and
/// yardages. Everything made in the map editor is kept: features, centerlines, tee box
/// assignments, combo tees, the map coordinate, and tee colors. Tees added by the fetched course
/// get no tee box. They must be assigned, deleted, or marked as combo tees by hand.
/// Sub-courses and holes are matched by position so renamed sub-courses still line up. Nothing is
/// removed: tees, sub-courses, and holes that the fetched course does not have are left as they are.
enum CourseInfoUpdater {
    static func merge(_ existing: Course, with fetched: Course) -> Course {
        var course = existing
        course.name = fetched.name
        course.clubName = fetched.clubName
        course.location.address = fetched.location.address
        course.location.city = fetched.location.city
        course.location.state = fetched.location.state
        course.location.country = fetched.location.country

        let existingColors = Dictionary(existing.tees.map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
        let fetchedNames = Set(fetched.tees.map(\.name))
        course.tees = fetched.tees.map { tee in
            TeeDefinition(name: tee.name, color: existingColors[tee.name] ?? tee.color)
        } + existing.tees.filter { !fetchedNames.contains($0.name) }

        for (subCourseIndex, fetchedSubCourse) in fetched.subCourses.enumerated() {
            guard subCourseIndex < course.subCourses.count else {
                course.subCourses.append(fetchedSubCourse)
                continue
            }
            course.subCourses[subCourseIndex].tees.merge(fetchedSubCourse.tees) { _, new in new }

            for (holeIndex, fetchedHole) in fetchedSubCourse.holes.enumerated() {
                guard holeIndex < course.subCourses[subCourseIndex].holes.count else {
                    course.subCourses[subCourseIndex].holes.append(fetchedHole)
                    continue
                }
                course.subCourses[subCourseIndex].holes[holeIndex].par = fetchedHole.par
                course.subCourses[subCourseIndex].holes[holeIndex].maleHandicap = fetchedHole.maleHandicap
                course.subCourses[subCourseIndex].holes[holeIndex].femaleHandicap = fetchedHole.femaleHandicap
                course.subCourses[subCourseIndex].holes[holeIndex].yardages.merge(fetchedHole.yardages) { _, new in new }
            }
        }
        return course
    }
}

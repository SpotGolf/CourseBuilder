import Foundation
import CourseDataSwift

/// The first time the map editor opens a course with no features, it checks OSM for course data
/// and offers to import it.
enum OSMCheck {
    /// Whether the map editor checks OSM when it opens the course.
    static func shouldCheck(_ course: Course, store: OSMCheckStore) -> Bool {
        course.features.isEmpty && !store.hasChecked(courseID: course.id)
    }

    /// Whether an OSM result holds anything to import.
    static func hasCourseData(_ result: OverpassAPIClient.ParsedResult) -> Bool {
        !result.features.isEmpty || !result.centerlines.isEmpty
    }
}

/// Records which courses have been checked for OSM data, so each is only checked once. They live
/// outside the courses folder, since ``CourseStore`` loads every `.json` file there as a course.
struct OSMCheckStore {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("CourseBuilder/osm-checks", isDirectory: true)
        }
    }

    func hasChecked(courseID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: courseID).path)
    }

    func markChecked(courseID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: fileURL(for: courseID), options: .atomic)
    }

    private func fileURL(for courseID: UUID) -> URL {
        directory.appendingPathComponent(courseID.uuidString)
    }
}

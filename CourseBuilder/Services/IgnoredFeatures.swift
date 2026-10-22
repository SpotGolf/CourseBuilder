import Foundation
import CourseDataSwift

/// Features the user marked as not part of the golf course. They are taken out of the course,
/// so they are not in its data file, and kept aside so they can be brought back.
enum IgnoredFeatures {
    /// Moves the features with the given IDs out of the course and into `ignored`. Only features
    /// no hole uses can be ignored; centerlines and features in a hole are left alone.
    static func ignore(_ ids: Set<Int>, in course: inout Course, ignored: inout [Feature]) {
        let used = Set(course.subCourses.flatMap(\.holes).flatMap(\.features)).union(course.centerlineFeatureIDs)
        let moving = course.features.filter { ids.contains($0.id) && !used.contains($0.id) && $0.type != .centerline }
        let movingIDs = Set(moving.map(\.id))
        course.features.removeAll { movingIDs.contains($0.id) }
        ignored.append(contentsOf: moving)
    }

    /// The feature to select after the given IDs are taken out of a list: the first one after
    /// the last removed row, or the last one before it when the removed rows were at the end.
    /// Nil when nothing is left.
    static func nextSelection(afterRemoving ids: Set<Int>, from order: [Int]) -> Int? {
        guard let lastRemoved = order.lastIndex(where: ids.contains) else { return nil }
        if let after = order[(lastRemoved + 1)...].first(where: { !ids.contains($0) }) {
            return after
        }
        return order[..<lastRemoved].last { !ids.contains($0) }
    }

    /// Moves the ignored features with the given IDs back into the course, as unassociated
    /// features. A feature whose ID was taken in the meantime gets the next free ID.
    static func restore(_ ids: Set<Int>, to course: inout Course, ignored: inout [Feature]) {
        let restoring = ignored.filter { ids.contains($0.id) }
        ignored.removeAll { ids.contains($0.id) }
        for feature in restoring {
            if course.features.contains(where: { $0.id == feature.id }) {
                course.features.append(Feature(id: course.nextFeatureID, type: feature.type, polygon: feature.polygon, osmID: feature.osmID))
            } else {
                course.features.append(feature)
            }
        }
    }
}

/// Reads and writes each course's ignored features. They live outside the courses folder,
/// since ``CourseStore`` loads every `.json` file there as a course.
struct IgnoredFeatureStore {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("CourseBuilder/ignored-features", isDirectory: true)
        }
    }

    func load(courseID: UUID) throws -> [Feature] {
        let url = fileURL(for: courseID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Feature].self, from: Data(contentsOf: url))
    }

    func save(_ features: [Feature], courseID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(features).write(to: fileURL(for: courseID), options: .atomic)
    }

    private func fileURL(for courseID: UUID) -> URL {
        directory.appendingPathComponent("\(courseID).json")
    }
}

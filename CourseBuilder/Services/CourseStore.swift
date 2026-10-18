import SwiftUI
import CourseDataSwift

class CourseStore: ObservableObject {
    @Published var courses: [Course] = []

    /// Looks up elevations for points that edits add or move.
    let elevationWorker: ElevationWorker

    private let directory: URL
    private let writer: CourseFileWriter
    private var pendingSaveTasks: [UUID: Task<Void, Never>] = [:]

    init(directory: URL? = nil, elevationWorker: ElevationWorker = ElevationWorker()) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("CourseBuilder/courses", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        writer = CourseFileWriter(directory: self.directory)

        self.elevationWorker = elevationWorker
        elevationWorker.read = { [weak self] id in
            self?.courses.first { $0.id == id }
        }
        elevationWorker.modify = { [weak self] id, change in
            self?.modify(id, change)
        }
    }

    func save(_ course: Course) throws {
        pendingSaveTasks[course.id]?.cancel()
        pendingSaveTasks[course.id] = nil
        try writer.write(course, version: writer.nextVersion(for: course.id))

        if let index = courses.firstIndex(where: { $0.id == course.id }) {
            courses[index] = course
        } else {
            courses.append(course)
        }
    }

    /// Returns a stable binding to the store-owned course. Changes are visible to every
    /// window immediately and are persisted to disk after a short debounce.
    func binding(for id: UUID) -> Binding<Course>? {
        guard let course = courses.first(where: { $0.id == id }) else { return nil }

        return Binding(
            get: { [weak self] in
                self?.courses.first(where: { $0.id == id }) ?? course
            },
            set: { [weak self] updatedCourse in
                self?.update(updatedCourse)
            }
        )
    }

    private func update(_ course: Course) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index] = course
        scheduleSave(for: course.id)
        elevationWorker.courseDidChange(course.id)
    }

    /// Changes a course in place without telling the elevation worker, which made the change.
    private func modify(_ id: UUID, _ change: (inout Course) -> Void) {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        change(&courses[index])
        scheduleSave(for: id)
    }

    /// Writes the course to disk once edits pause. Encoding a large course takes long enough to
    /// stall the UI, so the file is written on a background thread.
    private func scheduleSave(for id: UUID) {
        pendingSaveTasks[id]?.cancel()
        pendingSaveTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  let self,
                  let course = self.courses.first(where: { $0.id == id }) else { return }
            self.pendingSaveTasks[id] = nil
            let writer = self.writer
            let version = writer.nextVersion(for: id)
            Task.detached(priority: .utility) {
                try? writer.write(course, version: version)
            }
        }
    }

    func load(id: UUID) throws -> Course? {
        let fileURL = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Course.self, from: data)
    }

    func listCourses() throws -> [Course] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let course = try? JSONDecoder().decode(Course.self, from: data) else { return nil }
            return course
        }
    }

    func delete(id: UUID) throws {
        pendingSaveTasks[id]?.cancel()
        pendingSaveTasks[id] = nil
        elevationWorker.cancel(id)
        let fileURL = directory.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: fileURL)
        courses.removeAll { $0.id == id }
    }

    func loadAll() throws {
        courses = try listCourses()
    }
}

/// Writes course files. A write is skipped if a newer version of the same course was already
/// written, so a slow background write can never replace a newer file.
final class CourseFileWriter: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var issuedVersions: [UUID: Int] = [:]
    private var writtenVersions: [UUID: Int] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// Returns a version number higher than any issued before for the course.
    func nextVersion(for id: UUID) -> Int {
        lock.withLock {
            let version = (issuedVersions[id] ?? 0) + 1
            issuedVersions[id] = version
            return version
        }
    }

    func write(_ course: Course, version: Int) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(course)
        let fileURL = directory.appendingPathComponent("\(course.id).json")

        try lock.withLock {
            guard version > (writtenVersions[course.id] ?? 0) else { return }
            try data.write(to: fileURL)
            writtenVersions[course.id] = version
        }
    }
}

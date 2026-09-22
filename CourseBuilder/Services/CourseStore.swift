import SwiftUI
import CourseDataSwift

class CourseStore: ObservableObject {
    @Published var courses: [Course] = []

    private let directory: URL
    private var pendingSaveTasks: [UUID: Task<Void, Never>] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("CourseBuilder/courses", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func save(_ course: Course) throws {
        try write(course)

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
    }

    private func scheduleSave(for id: UUID) {
        pendingSaveTasks[id]?.cancel()
        pendingSaveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  let self,
                  let course = self.courses.first(where: { $0.id == id }) else { return }
            try? self.write(course)
            self.pendingSaveTasks[id] = nil
        }
    }

    private func write(_ course: Course) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(course)
        let fileURL = directory.appendingPathComponent("\(course.id).json")
        try data.write(to: fileURL)
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
        let fileURL = directory.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: fileURL)
        courses.removeAll { $0.id == id }
    }

    func loadAll() throws {
        courses = try listCourses()
    }
}

import Foundation

class CourseStore: ObservableObject {
    @Published var courses: [Course] = []

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("CourseData/courses", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func save(_ course: Course) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(course)
        let fileURL = directory.appendingPathComponent("\(course.id).json")
        try data.write(to: fileURL)

        if let index = courses.firstIndex(where: { $0.id == course.id }) {
            courses[index] = course
        } else {
            courses.append(course)
        }
    }

    func load(id: String) throws -> Course? {
        let fileURL = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Course.self, from: data)
    }

    func listCourses() throws -> [Course] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try files.map { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Course.self, from: data)
        }
    }

    func delete(id: String) throws {
        let fileURL = directory.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: fileURL)
        courses.removeAll { $0.id == id }
    }

    func loadAll() throws {
        courses = try listCourses()
    }
}

import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("Course file writer")
struct CourseFileWriterTests {
    @Test func olderVersionDoesNotReplaceNewerFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = CourseFileWriter(directory: directory)
        var course = Course(
            name: "Old",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 0, lon: 0))
        )
        let oldVersion = writer.nextVersion(for: course.id)
        let newVersion = writer.nextVersion(for: course.id)

        course.name = "New"
        try writer.write(course, version: newVersion)
        course.name = "Old"
        try writer.write(course, version: oldVersion)

        let data = try Data(contentsOf: directory.appendingPathComponent("\(course.id).json"))
        #expect(try JSONDecoder().decode(Course.self, from: data).name == "New")
    }
}

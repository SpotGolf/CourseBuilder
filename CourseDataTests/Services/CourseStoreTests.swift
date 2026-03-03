import XCTest
@testable import CourseData

final class CourseStoreTests: XCTestCase {
    var tempDir: URL!
    var store: CourseStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = CourseStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        let course = makeCourse(id: "test-course")
        try store.save(course)

        let loaded = try store.load(id: "test-course")
        XCTAssertEqual(loaded?.name, course.name)
        XCTAssertEqual(loaded?.id, "test-course")
    }

    func testListCourses() throws {
        try store.save(makeCourse(id: "course-a"))
        try store.save(makeCourse(id: "course-b"))

        let list = try store.listCourses()
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.contains(where: { $0.id == "course-a" }))
        XCTAssertTrue(list.contains(where: { $0.id == "course-b" }))
    }

    func testDeleteCourse() throws {
        try store.save(makeCourse(id: "to-delete"))
        XCTAssertNotNil(try store.load(id: "to-delete"))

        try store.delete(id: "to-delete")
        XCTAssertNil(try store.load(id: "to-delete"))
    }

    func testOverwriteExisting() throws {
        var course = makeCourse(id: "overwrite-me")
        try store.save(course)

        course.name = "Updated Name"
        try store.save(course)

        let loaded = try store.load(id: "overwrite-me")
        XCTAssertEqual(loaded?.name, "Updated Name")
    }

    func testLoadNonexistent() throws {
        let loaded = try store.load(id: "does-not-exist")
        XCTAssertNil(loaded)
    }

    private func makeCourse(id: String) -> Course {
        Course(
            id: id,
            name: "Test Course",
            location: CourseLocation(
                city: "Denver",
                state: "CO",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            )
        )
    }
}

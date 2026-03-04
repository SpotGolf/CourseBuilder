import XCTest
@testable import CourseData

final class CourseStoreTests: XCTestCase {
    var tempDir: URL!
    var store: CourseStore!

    private let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

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
        let course = makeCourse(id: idA)
        try store.save(course)

        let loaded = try store.load(id: idA)
        XCTAssertEqual(loaded?.name, course.name)
        XCTAssertEqual(loaded?.id, idA)
    }

    func testListCourses() throws {
        try store.save(makeCourse(id: idA))
        try store.save(makeCourse(id: idB))

        let list = try store.listCourses()
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.contains(where: { $0.id == self.idA }))
        XCTAssertTrue(list.contains(where: { $0.id == self.idB }))
    }

    func testDeleteCourse() throws {
        try store.save(makeCourse(id: idA))
        XCTAssertNotNil(try store.load(id: idA))

        try store.delete(id: idA)
        XCTAssertNil(try store.load(id: idA))
    }

    func testOverwriteExisting() throws {
        var course = makeCourse(id: idA)
        try store.save(course)

        course.name = "Updated Name"
        try store.save(course)

        let loaded = try store.load(id: idA)
        XCTAssertEqual(loaded?.name, "Updated Name")
    }

    func testLoadNonexistent() throws {
        let loaded = try store.load(id: UUID())
        XCTAssertNil(loaded)
    }

    private func makeCourse(id: UUID) -> Course {
        Course(
            id: id,
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Denver",
                state: "CO",
                country: "",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            )
        )
    }
}

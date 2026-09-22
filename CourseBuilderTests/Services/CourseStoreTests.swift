import XCTest
import Testing
@testable import CourseBuilder
import CourseDataSwift

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

@Suite("Shared course bindings")
struct SharedCourseBindingTests {
    @Test("Edits from separate windows remain synchronized")
    func editsRemainSynchronized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CourseStore(directory: directory)
        var hole = Hole(number: 1, par: 4)
        hole.yardages["Blue"] = 0
        let course = Course(
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Denver",
                state: "CO",
                country: "US",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            ),
            tees: [
                TeeDefinition(name: "Blue", color: "#0000FF"),
                TeeDefinition(name: "White", color: "#FFFFFF")
            ],
            subCourses: [SubCourse(name: "Front", holes: [hole])]
        )
        try store.save(course)

        let mainBinding = try #require(store.binding(for: course.id))
        let mapBinding = try #require(store.binding(for: course.id))

        var mainEdit = mainBinding.wrappedValue
        mainEdit.subCourses[0].holes[0].yardages["Blue"] = 420
        mainBinding.wrappedValue = mainEdit

        #expect(mapBinding.wrappedValue.subCourses[0].holes[0].yardages["Blue"] == 420)

        var mapEdit = mapBinding.wrappedValue
        mapEdit.features.append(Feature(id: 1, type: .green, polygon: []))
        mapBinding.wrappedValue = mapEdit

        #expect(mainBinding.wrappedValue.subCourses[0].holes[0].yardages["Blue"] == 420)

        var teeEdit = mainBinding.wrappedValue
        teeEdit.tees.removeAll { $0.name == "Blue" }
        mainBinding.wrappedValue = teeEdit

        #expect(mapBinding.wrappedValue.tees.map(\.name) == ["White"])
    }
}

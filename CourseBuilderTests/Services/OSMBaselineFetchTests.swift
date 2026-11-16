import Foundation
import Testing
import CourseDataSwift
@testable import CourseBuilder

@MainActor
@Suite("OSM baseline fetch")
struct OSMBaselineFetchTests {
    private let square: CoordinatePath = [
        Coordinate(lat: 40, lon: -105), Coordinate(lat: 40.001, lon: -105), Coordinate(lat: 40.001, lon: -105.001),
    ]

    private func makeCourse(osmIDs: [String]) -> Course {
        Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
            features: osmIDs.enumerated().map { Feature(id: $0.offset + 1, type: .green, polygon: square, osmID: $0.element) },
            subCourses: [SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])]
        )
    }

    @Test func courseWithNoOSMShapesNeedsNothing() {
        let course = makeCourse(osmIDs: [])
        #expect(!OSMBaselineFetch.isNeeded(for: OSMBaseline(course: course), course: course))
    }

    @Test func recordFromAnImportNeedsNothing() {
        let course = makeCourse(osmIDs: ["w1"])
        var baseline = OSMBaseline(course: course, details: ["w1": OSMElementDetails(version: 1, tags: ["golf": "green"])])
        baseline.checkedCourseElement = true
        baseline.checkedCourseOSMID = true
        #expect(!OSMBaselineFetch.isNeeded(for: baseline, course: course))
    }

    /// An outline around the test course's shapes.
    private var outline: [Coordinate] {
        [Coordinate(lat: 39.99, lon: -105.01), Coordinate(lat: 40.01, lon: -105.01),
         Coordinate(lat: 40.01, lon: -104.99), Coordinate(lat: 39.99, lon: -104.99)]
    }

    @Test func oldCourseGetsTheIDOfItsOutline() async throws {
        var course = makeCourse(osmIDs: ["w1"])
        var baseline = OSMBaseline(course: course, details: ["w1": OSMElementDetails(tags: [:])])
        baseline.checkedCourseElement = true
        #expect(OSMBaselineFetch.isNeeded(for: baseline, course: course))
        let outline = outline

        try await OSMBaselineFetch.run(
            baseline: &baseline,
            course: &course,
            detailsFetch: { _ in [:] },
            courseElementsFetch: { _ in .init(outlineOSMID: "w77", outline: outline) }
        )

        #expect(course.osmID == "w77")
        #expect(!OSMBaselineFetch.isNeeded(for: baseline, course: course))
    }

    @Test func outlineOfANeighboringCourseIsNotTaken() async throws {
        var course = makeCourse(osmIDs: ["w1"])
        var baseline = OSMBaseline(course: course, details: ["w1": OSMElementDetails(tags: [:])])
        let elsewhere = outline.map { Coordinate(lat: $0.lat + 1, lon: $0.lon) }

        try await OSMBaselineFetch.run(
            baseline: &baseline,
            course: &course,
            detailsFetch: { _ in [:] },
            courseElementsFetch: { _ in .init(outlineOSMID: "w88", outline: elsewhere) }
        )

        #expect(course.osmID == nil)
        // It was looked for, so it is not asked for again.
        #expect(!OSMBaselineFetch.isNeeded(for: baseline, course: course))
    }

    @Test func courseWithAnIDIsNotAskedForIt() {
        var course = makeCourse(osmIDs: ["w1"])
        course.osmID = "w77"
        var baseline = OSMBaseline(course: course, details: ["w1": OSMElementDetails(tags: [:])])
        baseline.checkedCourseElement = true
        #expect(!OSMBaselineFetch.isNeeded(for: baseline, course: course))
    }

    @Test func fetchesTagsAndTheCourseOutlineThenNeedsNothing() async throws {
        var course = makeCourse(osmIDs: ["w1", "w2"])
        var baseline = OSMBaseline(course: course)
        #expect(OSMBaselineFetch.isNeeded(for: baseline, course: course))
        let node = MisplacedCourseElement(osmID: "n9", tags: ["leisure": "golf_course"], center: Coordinate(lat: 40, lon: -105))
        var steps: [OSMBaselineFetch.Progress] = []

        try await OSMBaselineFetch.run(
            baseline: &baseline,
            course: &course,
            detailsFetch: { osmIDs in
                Dictionary(uniqueKeysWithValues: osmIDs.map { ($0, OSMElementDetails(version: 3, tags: ["id": $0])) })
            },
            courseElementsFetch: { _ in .init(misplaced: [node]) },
            progress: { steps.append($0) }
        )

        #expect(steps == [.details(shapes: 2), .courseOutline])
        #expect(baseline.entries["w1"]?.tags == ["id": "w1"])
        #expect(baseline.entries["w2"]?.tags == ["id": "w2"])
        #expect(baseline.misplacedCourseElement == node)
        #expect(baseline.checkedCourseElement)
        #expect(!OSMBaselineFetch.isNeeded(for: baseline, course: course))
    }

    @Test func shapeOSMGivesNothingForIsNotAskedForAgain() async throws {
        var course = makeCourse(osmIDs: ["w1", "w2"])
        var baseline = OSMBaseline(course: course)

        try await OSMBaselineFetch.run(
            baseline: &baseline,
            course: &course,
            detailsFetch: { _ in ["w1": OSMElementDetails(tags: [:])] },
            courseElementsFetch: { _ in .init() }
        )

        #expect(baseline.osmIDsWithoutDetails == ["w2"])
        #expect(baseline.entries["w2"]?.tags == nil)
        #expect(!OSMBaselineFetch.isNeeded(for: baseline, course: course))
    }

    @Test func failedOutlineCheckKeepsTheTagsAndIsStillNeeded() async {
        var course = makeCourse(osmIDs: ["w1"])
        var baseline = OSMBaseline(course: course)
        let asked = AskLog()

        await #expect(throws: URLError.self) {
            try await OSMBaselineFetch.run(
                baseline: &baseline,
                course: &course,
                detailsFetch: { osmIDs in
                    await asked.record(osmIDs)
                    return ["w1": OSMElementDetails(tags: ["golf": "green"])]
                },
                courseElementsFetch: { _ in throw URLError(.timedOut) }
            )
        }
        #expect(baseline.entries["w1"]?.tags == ["golf": "green"])
        #expect(!baseline.checkedCourseElement)
        #expect(OSMBaselineFetch.isNeeded(for: baseline, course: course))

        // A retry only asks for what is still missing.
        try? await OSMBaselineFetch.run(
            baseline: &baseline,
            course: &course,
            detailsFetch: { osmIDs in
                await asked.record(osmIDs)
                return [:]
            },
            courseElementsFetch: { _ in .init() }
        )
        #expect(await asked.requests == [["w1"]])
        #expect(!OSMBaselineFetch.isNeeded(for: baseline, course: course))
    }

    @Test func recordIsSavedAndLoadedWithWhatOSMDidNotGive() throws {
        var baseline = OSMBaseline(course: makeCourse(osmIDs: ["w1"]))
        baseline.osmIDsWithoutDetails = ["w1"]

        let decoded = try JSONDecoder().decode(OSMBaseline.self, from: JSONEncoder().encode(baseline))

        #expect(decoded.osmIDsWithoutDetails == ["w1"])
    }
}

private actor AskLog {
    private(set) var requests: [[String]] = []
    func record(_ osmIDs: [String]) { requests.append(osmIDs) }
}

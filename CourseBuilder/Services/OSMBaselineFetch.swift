import Foundation
import CourseDataSwift

/// Fetches what a course's OpenStreetMap record is missing, so the course is ready to publish
/// from. A course added with its OpenStreetMap data already has all of it. Only a course from
/// an older version of the app, or one imported from a file, has anything to fetch.
///
/// Three things can be missing:
/// - The tags and members of the course's OpenStreetMap shapes. Publishing sends them back
///   with a changed shape, so they are not lost.
/// - The `leisure=golf_course` element that is not a usable course outline, if there is one.
///   Fix Course Outline needs it.
/// - The OpenStreetMap ID of the course outline, which is exported as the course's own ID.
enum OSMBaselineFetch {
    /// Reads the tags and members of ways and relations, by OSM ID such as `w123`.
    typealias DetailsFetch = @Sendable ([String]) async throws -> [String: OSMElementDetails]
    /// Reads the `leisure=golf_course` elements in an area.
    typealias CourseElementsFetch = @Sendable (OverpassAPIClient.BoundingBox) async throws -> OverpassAPIClient.CourseElements

    static let osmDetailsFetch: DetailsFetch = { osmIDs in
        try await OSMAPIClient.details(of: osmIDs)
    }

    static let overpassCourseElementsFetch: CourseElementsFetch = { bbox in
        try await OverpassAPIClient().fetchCourseElements(bbox: bbox)
    }

    /// What the fetch is doing, for the user.
    enum Progress: Equatable {
        case details(shapes: Int)
        case courseOutline

        var message: String {
            switch self {
            case .details(let shapes):
                "Tags of \(shapes.formatted()) \(shapes == 1 ? "shape" : "shapes")"
            case .courseOutline:
                "Course outline"
            }
        }
    }

    /// Whether the record is missing anything that can be fetched.
    static func isNeeded(for baseline: OSMBaseline, course: Course) -> Bool {
        !osmIDsToFetch(in: baseline).isEmpty || courseElementArea(for: baseline, course: course) != nil
    }

    /// Fetches what is missing. Throws if OpenStreetMap cannot be reached or answers with an
    /// error. What was fetched before the error stays in `baseline`, so calling again only
    /// asks for the rest.
    ///
    /// The course only changes when the ID of its outline is found. Save the course and the
    /// record together, since the record remembers that the ID was looked for.
    @MainActor
    static func run(
        baseline: inout OSMBaseline,
        course: inout Course,
        detailsFetch: DetailsFetch = osmDetailsFetch,
        courseElementsFetch: CourseElementsFetch = overpassCourseElementsFetch,
        progress: @MainActor (Progress) -> Void = { _ in }
    ) async throws {
        let osmIDs = osmIDsToFetch(in: baseline)
        if !osmIDs.isEmpty {
            progress(.details(shapes: osmIDs.count))
            let details = try await detailsFetch(osmIDs)
            try Task.checkCancellation()
            baseline.fillDetails(details)
            // What OpenStreetMap did not give is not asked for again.
            baseline.osmIDsWithoutDetails.formUnion(baseline.osmIDsWithUnknownDetails)
        }

        if let area = courseElementArea(for: baseline, course: course) {
            progress(.courseOutline)
            let elements = try await courseElementsFetch(area)
            try Task.checkCancellation()
            if !baseline.checkedCourseElement {
                baseline.misplacedCourseElement = CourseOutline.nearest(elements.misplaced, to: course.location.coordinate)
                baseline.checkedCourseElement = true
            }
            if course.osmID == nil, let osmID = elements.outlineOSMID, let outline = elements.outline,
               let middle = middle(of: course), PolygonGeometry.contains(middle, in: outline) {
                course.osmID = osmID
            }
            baseline.checkedCourseOSMID = true
        }
    }

    /// The middle of the course's shapes. An outline is only taken as this course's when it
    /// is around this point, since the search area can reach a neighboring course.
    private static func middle(of course: Course) -> Coordinate? {
        let points = course.features.flatMap(\.polygon)
        guard !points.isEmpty else { return nil }
        return Coordinate(
            lat: points.map(\.lat).reduce(0, +) / Double(points.count),
            lon: points.map(\.lon).reduce(0, +) / Double(points.count)
        )
    }

    /// The OSM IDs whose tags or members are unknown and were not asked for yet.
    private static func osmIDsToFetch(in baseline: OSMBaseline) -> [String] {
        baseline.osmIDsWithUnknownDetails.filter { !baseline.osmIDsWithoutDetails.contains($0) }
    }

    /// Where to look for the course's `leisure=golf_course` elements. Nil when they were looked
    /// for already, or the course has no OpenStreetMap shapes.
    private static func courseElementArea(for baseline: OSMBaseline, course: Course) -> OverpassAPIClient.BoundingBox? {
        let needsOutlineID = course.osmID == nil && !baseline.checkedCourseOSMID
        guard !baseline.checkedCourseElement || needsOutlineID, !baseline.entries.isEmpty else { return nil }
        return OverpassAPIClient.BoundingBox(containing: course.features.flatMap(\.polygon))?.padded(by: 0.25)
    }
}

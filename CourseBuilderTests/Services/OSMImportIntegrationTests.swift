import XCTest
@testable import CourseBuilder

/// Integration tests that hit real APIs (GolfCourseAPI + Overpass).
/// These require a GolfCourseAPI key set in the GOLF_COURSE_API_KEY environment variable.
/// To run: Edit scheme > Test > Arguments > Environment Variables > GOLF_COURSE_API_KEY = <your key>
final class OSMImportIntegrationTests: XCTestCase {
    private var apiKey: String!

    override func setUp() {
        apiKey = ProcessInfo.processInfo.environment["GOLF_COURSE_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "golfCourseAPIKey")
    }

    /// Search for "omni interlocken", fetch all 3 nine-hole courses from GolfCourseAPI,
    /// convert them into a single Course with 3 sub-courses, fetch OSM data, and verify
    /// that centerline grouping produces 3 groups (one per nine).
    func testOmniInterlockenCenterlineGrouping() async throws {
        try XCTSkipIf(apiKey == nil, "GOLF_COURSE_API_KEY not set")

        // Step 1: Search GolfCourseAPI for Omni Interlocken
        let client = GolfCourseAPIClient(apiKey: apiKey)
        let response = try await client.search(query: "omni interlocken")
        XCTAssertFalse(response.courses.isEmpty, "Should find Omni Interlocken courses")

        // Filter to just the Omni Interlocken results (there should be 3 nine-hole courses)
        let omniResults = response.courses.filter {
            $0.clubName.lowercased().contains("interlocken") ||
            $0.courseName.lowercased().contains("interlocken")
        }
        XCTAssertEqual(omniResults.count, 3, "Should find 3 Omni Interlocken courses, got: \(omniResults.map { "\($0.courseName) (\($0.holes ?? 0) holes)" })")

        // Step 2: Fetch details for all 3 courses
        var details: [GolfCourseAPIClient.CourseDetail] = []
        for result in omniResults {
            let detail = try await client.fetchCourse(id: result.id)
            details.append(detail)
        }

        // Step 3: Convert to a single Course with 3 sub-courses
        let course = try GolfCourseAPIClient.convertToCourse(details: details)
        XCTAssertEqual(course.subCourses.count, 3, "Should have 3 sub-courses, got: \(course.subCourses.map(\.name))")

        let totalHoles = course.subCourses.flatMap(\.holes).count
        XCTAssertEqual(totalHoles, 27, "Should have 27 total holes")

        // Log sub-course info for debugging
        for (i, sc) in course.subCourses.enumerated() {
            let yardages = sc.holes.map { hole in
                hole.yardages.values.max() ?? 0
            }
            print("Sub-course \(i): \(sc.name) — \(sc.holes.count) holes, max yardages: \(yardages)")
        }

        // Step 4: Fetch OSM data for this course
        let osmClient = OverpassAPIClient()
        let searchBBox = OverpassAPIClient.boundingBox(around: course.location.coordinate, radiusMeters: 1000)
        let osmResult = try await osmClient.fetchFeatures(bbox: searchBBox)

        // If there's a course boundary, refetch within it
        var finalResult = osmResult
        if let boundary = osmResult.courseBoundary, boundary.count >= 3 {
            let lats = boundary.map(\.latitude)
            let lons = boundary.map(\.longitude)
            let bbox = OverpassAPIClient.BoundingBox(
                south: lats.min()!, west: lons.min()!,
                north: lats.max()!, east: lons.max()!
            ).padded(by: 0.25)
            finalResult = try await osmClient.fetchFeatures(bbox: bbox)
        }

        print("OSM returned \(finalResult.centerlines.count) centerlines, \(finalResult.features.count) features")

        // Log centerline hole numbers
        let holeNumbers = finalResult.centerlines.compactMap(\.holeNumber).sorted()
        print("Centerline hole numbers: \(holeNumbers)")

        // Check for duplicates
        let uniqueNumbers = Set(holeNumbers)
        let hasDuplicates = uniqueNumbers.count < holeNumbers.count
        print("Has duplicate hole numbers: \(hasDuplicates)")
        if hasDuplicates {
            for num in uniqueNumbers.sorted() {
                let count = holeNumbers.filter { $0 == num }.count
                if count > 1 {
                    print("  Hole \(num): \(count) centerlines")
                }
            }
        }

        // Step 5: Test the centerline grouping
        // This calls the same logic the MapEditorView uses
        let subCourseSizes = course.subCourses.map(\.holes.count)
        let groups = buildCenterlineGroups(from: finalResult.centerlines, subCourseSizes: subCourseSizes)

        print("Centerline groups: \(groups.count)")
        for (i, group) in groups.enumerated() {
            let numbers = group.centerlines.compactMap(\.holeNumber)
            print("  Group \(i): \(group.label) — \(group.centerlines.count) centerlines, numbers: \(numbers)")
        }

        XCTAssertEqual(groups.count, 3, "Should produce 3 centerline groups for 3 nines, got \(groups.count): \(groups.map(\.label))")

        // Each group should have 9 centerlines
        for group in groups {
            XCTAssertEqual(group.centerlines.count, 9, "Each group should have 9 centerlines, '\(group.label)' has \(group.centerlines.count)")
        }
    }

    // MARK: - Centerline Grouping Logic (mirrors MapEditorView)

    struct TestCenterlineGroup {
        let label: String
        let centerlines: [OverpassAPIClient.ParsedCenterline]
    }

    private func buildCenterlineGroups(
        from centerlines: [OverpassAPIClient.ParsedCenterline],
        subCourseSizes: [Int]
    ) -> [TestCenterlineGroup] {
        let valid = centerlines.filter { $0.holeNumber != nil && $0.coordinates.count >= 2 }
        guard !valid.isEmpty, !subCourseSizes.isEmpty else { return [] }

        let maxChainLength = subCourseSizes.max() ?? 9
        var used: Set<Int> = []
        var groups: [TestCenterlineGroup] = []

        let starts = valid.enumerated().filter { $0.element.holeNumber == 1 }

        for (startIdx, startCL) in starts {
            if used.contains(startIdx) { continue }

            var chain: [OverpassAPIClient.ParsedCenterline] = [startCL]
            used.insert(startIdx)
            var currentEnd = startCL.coordinates.last!

            var nextRef = 2
            while chain.count < maxChainLength {
                var bestIdx: Int?
                var bestDist = Double.greatestFiniteMagnitude
                for (i, cl) in valid.enumerated() {
                    guard cl.holeNumber == nextRef, !used.contains(i) else { continue }
                    let dist = cl.coordinates.first!.clLocation.distance(from: currentEnd.clLocation)
                    if dist < bestDist {
                        bestDist = dist
                        bestIdx = i
                    }
                }

                guard let idx = bestIdx else { break }
                chain.append(valid[idx])
                used.insert(idx)
                currentEnd = valid[idx].coordinates.last!
                nextRef += 1
            }

            groups.append(TestCenterlineGroup(
                label: "\(chain.count) holes (group \(groups.count + 1))",
                centerlines: chain
            ))
        }

        let remaining = valid.enumerated().filter { !used.contains($0.offset) }
        if !remaining.isEmpty {
            let sortedRemaining = remaining.sorted { ($0.element.holeNumber ?? 0) < ($1.element.holeNumber ?? 0) }
            var remainingUsed: Set<Int> = []

            for (startIdx, startCL) in sortedRemaining {
                if remainingUsed.contains(startIdx) { continue }

                var chain: [OverpassAPIClient.ParsedCenterline] = [startCL]
                remainingUsed.insert(startIdx)
                var currentEnd = startCL.coordinates.last!
                let startRef = startCL.holeNumber ?? 0

                var nextRef = startRef + 1
                while chain.count < maxChainLength {
                    var bestIdx: Int?
                    var bestDist = Double.greatestFiniteMagnitude
                    for (idx, cl) in sortedRemaining {
                        guard cl.holeNumber == nextRef, !remainingUsed.contains(idx) else { continue }
                        let dist = cl.coordinates.first!.clLocation.distance(from: currentEnd.clLocation)
                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = idx
                        }
                    }

                    guard let idx = bestIdx else { break }
                    chain.append(valid[idx])
                    remainingUsed.insert(idx)
                    currentEnd = valid[idx].coordinates.last!
                    nextRef += 1
                }

                groups.append(TestCenterlineGroup(
                    label: "\(chain.count) holes (group \(groups.count + 1))",
                    centerlines: chain
                ))
            }
        }

        return groups
    }
}

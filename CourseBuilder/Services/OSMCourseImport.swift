import CoreLocation
import Foundation
import os
import SwiftUI
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "OSMCourseImport")

/// The steps that bring a course's OpenStreetMap data into a course: read it, group its holes
/// for the user to assign to sub-courses, and add it to the course.
enum OSMCourseImport {
    /// How many times a lookup is tried when the network fails. The Overpass client itself
    /// retries rate limits and server errors.
    static let maxAttempts = 3

    /// Reads the golf features around a point from OSM.
    ///
    /// - Parameters:
    ///   - coordinate: The course's location, such as its clubhouse.
    ///   - status: Called on the main thread with what the lookup is doing.
    @MainActor
    static func fetch(
        around coordinate: Coordinate,
        client: OverpassAPIClient = OverpassAPIClient(),
        retryDelay: Duration = .seconds(2),
        status: (String) -> Void
    ) async throws -> OverpassAPIClient.ParsedResult {
        var attempt = 1
        while true {
            do {
                return try await fetchOnce(around: coordinate, client: client, status: status)
            } catch let error as URLError where error.code != .cancelled && attempt < maxAttempts {
                logger.error("OSM lookup failed (attempt \(attempt, privacy: .public)): \(error, privacy: .public)")
                attempt += 1
                status("The network failed. Trying again (try \(attempt) of \(maxAttempts))...")
                try await Task.sleep(for: retryDelay * (attempt - 1))
            }
        }
    }

    @MainActor
    private static func fetchOnce(
        around coordinate: Coordinate,
        client: OverpassAPIClient,
        status: (String) -> Void
    ) async throws -> OverpassAPIClient.ParsedResult {
        status("Searching within 1 km of the course location...")
        let searchBBox = OverpassAPIClient.boundingBox(around: coordinate, radiusMeters: 1000)
        let result = try await client.fetchFeatures(bbox: searchBBox)
        logger.info("Initial query: \(result.features.count, privacy: .public) features, \(result.centerlines.count, privacy: .public) centerlines, boundary: \(result.courseBoundary != nil, privacy: .public)")

        var finalResult = result
        if let bbox = OverpassAPIClient.boundaryBoundingBox(for: result.courseBoundary) {
            status("Found \(result.features.count) features and a course outline. Reading everything inside the outline...")
            finalResult = try await client.fetchFeatures(bbox: bbox)
            logger.info("Full query: \(finalResult.features.count, privacy: .public) features")
        } else {
            // No outline: grow the search area until it holds every golf feature found.
            var bbox = searchBBox
            for step in 1...OverpassAPIClient.maximumGrowthFetches {
                guard let grown = OverpassAPIClient.grownBoundingBox(bbox, for: finalResult) else { break }
                status("Found \(finalResult.features.count) features. Widening the search past the edge of the course (step \(step) of up to \(OverpassAPIClient.maximumGrowthFetches))...")
                bbox = grown
                finalResult = try await client.fetchFeatures(bbox: bbox)
                logger.info("Grown query: \(finalResult.features.count, privacy: .public) features")
            }
        }

        // A relation reaching into the search area can have inner ways, such as greens, outside it.
        let missingInnerWayIDs = finalResult.missingInnerWayIDs
        if !missingInnerWayIDs.isEmpty {
            status("Found \(finalResult.features.count) features. Reading \(missingInnerWayIDs.count) more that belong to them...")
            finalResult = finalResult.adding(try await client.fetchWays(ids: missingInnerWayIDs))
            logger.info("Inner way query: \(finalResult.features.count, privacy: .public) features")
        }

        return finalResult
    }

    /// The OSM holes in groups for the user to assign to sub-courses. A group whose holes are
    /// numbered like a sub-course's, such as 1 to 9 or 10 to 18, starts out assigned to it.
    static func centerlineGroups(
        from centerlines: [OverpassAPIClient.ParsedCenterline],
        subCourseSizes: [Int]
    ) -> [CenterlineGroup] {
        var groups = chains(from: centerlines, subCourseSizes: subCourseSizes)
        groups.assignNumberedSubCourses(subCourseSizes: subCourseSizes)
        return groups
    }

    /// Groups centerlines into chains by following them in playing order.
    ///
    /// Starting from each unvisited hole with ref=1, follow the chain: find the
    /// centerline with ref=2 whose start is nearest to the current hole's end,
    /// then ref=3, etc. Each chain is limited to the expected sub-course size
    /// to prevent jumping across nines (e.g., hole 9 → hole 10 on a different nine).
    /// Leftover centerlines (e.g., holes 10-18) form additional chains.
    private static func chains(
        from centerlines: [OverpassAPIClient.ParsedCenterline],
        subCourseSizes: [Int]
    ) -> [CenterlineGroup] {
        let valid = centerlines.filter { $0.holeNumber != nil && $0.coordinates.count >= 2 }
        guard !valid.isEmpty, !subCourseSizes.isEmpty else { return [] }

        let maxChainLength = subCourseSizes.max() ?? 9
        var used: Set<Int> = [] // indices into `valid`
        var groups: [CenterlineGroup] = []

        // Find all hole-1 centerlines as chain starting points
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

            groups.append(CenterlineGroup(
                label: "\(chain.count) holes (group \(groups.count + 1))",
                centerlines: chain,
                assignedSubCourseIndex: nil
            ))
        }

        // Pick up remaining centerlines (e.g., holes 10-18 with no ref=1 start)
        let remaining = valid.enumerated().filter { !used.contains($0.offset) }
        if !remaining.isEmpty {
            // Sort by ref and traverse
            let sortedRemaining = remaining.sorted { ($0.element.holeNumber ?? 0) < ($1.element.holeNumber ?? 0) }
            var remainingUsed: Set<Int> = []

            // Start chains from the lowest unused ref
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
                    let cl = valid[idx]
                    chain.append(cl)
                    remainingUsed.insert(idx)
                    currentEnd = cl.coordinates.last!
                    nextRef += 1
                }

                groups.append(CenterlineGroup(
                    label: "\(chain.count) holes (group \(groups.count + 1))",
                    centerlines: chain,
                    assignedSubCourseIndex: nil
                ))
            }
        }

        return groups
    }

    /// The version, tags, and members of each element in a result, by OSM ID.
    static func details(in result: OverpassAPIClient.ParsedResult) -> [String: OSMElementDetails] {
        var details: [String: OSMElementDetails] = [:]
        for feature in result.features {
            if let osmID = feature.osmID {
                details[osmID] = OSMElementDetails(version: feature.version, tags: feature.tags, members: feature.members)
            }
        }
        for centerline in result.centerlines {
            if let osmID = centerline.osmID {
                details[osmID] = OSMElementDetails(version: centerline.version, tags: centerline.tags)
            }
        }
        return details
    }

    /// A course with OSM data added, and the record of what OSM had.
    struct Imported {
        var course: Course
        var baseline: OSMBaseline
    }

    /// Adds a result's features to a course, and gives each assigned group's holes to its
    /// sub-course in order. Groups with no sub-course are left out: their features are still
    /// added, but no hole uses them. The course takes the OSM ID of its outline, if OSM has one.
    static func apply(
        _ result: OverpassAPIClient.ParsedResult,
        groups: [CenterlineGroup],
        to course: Course
    ) -> Imported {
        // Number each group's holes by where its sub-course's holes fall in the whole course.
        var renumbered: [OverpassAPIClient.ParsedCenterline] = []
        for group in groups {
            guard let subCourseIndex = group.assignedSubCourseIndex, course.subCourses.indices.contains(subCourseIndex) else { continue }
            let offset = course.subCourses[..<subCourseIndex].map(\.holes.count).reduce(0, +)
            for (holeIndex, centerline) in group.centerlines.enumerated() {
                renumbered.append(OverpassAPIClient.ParsedCenterline(
                    holeNumber: offset + holeIndex + 1,
                    coordinates: centerline.coordinates,
                    osmID: centerline.osmID,
                    version: centerline.version,
                    tags: centerline.tags
                ))
            }
        }

        var mapped = result
        mapped.centerlines = renumbered

        var imported = course
        OSMImporter.applyParsedResult(mapped, to: &imported)
        if let courseOSMID = result.courseOSMID {
            imported.osmID = courseOSMID
        }

        var baseline = OSMBaseline(course: imported, details: details(in: result))
        baseline.misplacedCourseElement = CourseOutline.nearest(result.misplacedCourseElements, to: course.location.coordinate)
        baseline.checkedCourseElement = true
        baseline.checkedCourseOSMID = true
        return Imported(course: imported, baseline: baseline)
    }
}

// MARK: - Centerline Mapping

/// A run of OSM holes that play one after another, such as a nine.
struct CenterlineGroup: Identifiable {
    let id = UUID()
    var label: String
    var centerlines: [OverpassAPIClient.ParsedCenterline]
    var assignedSubCourseIndex: Int?

    /// The color a group is drawn in, by its place in the list.
    static func color(for index: Int) -> Color {
        let colors: [Color] = [.red, .blue, .green, .orange, .purple, .cyan, .yellow, .pink, .mint]
        return colors[index % colors.count]
    }
}

extension [CenterlineGroup] {
    /// Removes a group and renumbers the groups after it.
    mutating func removeGroup(at index: Int) {
        remove(at: index)
        relabel()
    }

    /// Assigns each group to the sub-course whose holes it numbers. With nines of 9 holes, the
    /// group of holes 1–9 goes to the first sub-course and holes 10–18 to the second. Groups
    /// numbered any other way, or a second group for the same sub-course, stay unassigned.
    mutating func assignNumberedSubCourses(subCourseSizes: [Int]) {
        var firstHole = 1
        for (subCourseIndex, size) in subCourseSizes.enumerated() {
            let holes = [Int](firstHole..<(firstHole + size))
            firstHole += size
            guard size > 0, !contains(where: { $0.assignedSubCourseIndex == subCourseIndex }),
                  let match = firstIndex(where: {
                      $0.assignedSubCourseIndex == nil && $0.centerlines.compactMap(\.holeNumber).sorted() == holes
                  }) else { continue }
            self[match].assignedSubCourseIndex = subCourseIndex
        }
    }

    /// Sets each group's label from its hole count and its place in the list.
    mutating func relabel() {
        for index in indices {
            self[index].label = "\(self[index].centerlines.count) holes (group \(index + 1))"
        }
    }
}

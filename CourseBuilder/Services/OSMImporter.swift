import Foundation
import CoreLocation

enum OSMImporter {
    /// Apply parsed OSM data to a course. Runs Phases 1-4 on holes with centerlines first,
    /// then synthesizes centerlines for remaining holes from leftover features and runs
    /// Phases 1-4 again on those.
    static func applyParsedResult(_ result: OverpassAPIClient.ParsedResult, to course: inout Course) {
        // Create Feature objects with auto-incremented IDs
        var nextID = course.nextFeatureID
        var features: [Feature] = []
        for parsed in result.features {
            features.append(Feature(id: nextID, type: parsed.type, polygon: parsed.polygon))
            nextID += 1
        }
        course.features.append(contentsOf: features)

        // Build a flat list of (subCourseIndex, holeIndex, globalHoleNumber) for all holes
        var holeSlots: [(sub: Int, hole: Int, global: Int)] = []
        var globalNumber = 0
        for subIdx in course.subCourses.indices {
            for holeIdx in course.subCourses[subIdx].holes.indices {
                globalNumber += 1
                holeSlots.append((subIdx, holeIdx, globalNumber))
            }
        }

        // Assign centerlines to holes by matching OSM hole numbers to global numbers
        for slot in holeSlots {
            if let cl = result.centerlines.first(where: { $0.holeNumber == slot.global }) {
                course.subCourses[slot.sub].holes[slot.hole].centerline = cl.coordinates
            }
        }

        // Run Phases 1-4 on holes that have centerlines
        let holesWithCenterlines = holeSlots.filter { slot in
            !course.subCourses[slot.sub].holes[slot.hole].centerline.isEmpty
        }
        var assignedIDs: Set<Int> = []
        if !holesWithCenterlines.isEmpty {
            assignedIDs = associateFeatures(
                features, course: &course, holeSlots: holesWithCenterlines
            )
        }

        // For holes still missing centerlines, synthesize from leftover features
        let holesWithoutCenterlines = holeSlots.filter { slot in
            course.subCourses[slot.sub].holes[slot.hole].centerline.isEmpty
        }
        if !holesWithoutCenterlines.isEmpty {
            synthesizeCenterlines(
                for: holesWithoutCenterlines,
                features: features,
                alreadyAssigned: assignedIDs,
                course: &course
            )

            // Run Phases 1-4 on the newly-centerlined holes
            let nowHaveCenterlines = holesWithoutCenterlines.filter { slot in
                !course.subCourses[slot.sub].holes[slot.hole].centerline.isEmpty
            }
            if !nowHaveCenterlines.isEmpty {
                let unassigned = features.filter { !assignedIDs.contains($0.id) }
                _ = associateFeatures(
                    unassigned, course: &course, holeSlots: nowHaveCenterlines
                )
            }
        }
    }

    /// For each hole: find its green, walk tees forward along the centerline,
    /// associate remaining features, and assign tee names. Returns assigned feature IDs.
    @discardableResult
    private static func associateFeatures(
        _ features: [Feature],
        course: inout Course,
        holeSlots: [(sub: Int, hole: Int, global: Int)]
    ) -> Set<Int> {
        let metersPerYard = 0.9144
        let thresholdMeters = 35.0 * metersPerYard
        var assignedIDs: Set<Int> = []

        for slot in holeSlots {
            let cl = course.subCourses[slot.sub].holes[slot.hole].centerline

            // Step 1: Find the closest unassigned green to this hole's centerline endpoint
            var bestGreen: Feature?
            var bestGreenDist = Double.greatestFiniteMagnitude
            for feature in features where feature.type == .green && !assignedIDs.contains(feature.id) {
                let dist = feature.center.clLocation.distance(from: cl.last!.clLocation)
                if dist < bestGreenDist {
                    bestGreenDist = dist
                    bestGreen = feature
                }
            }
            if let green = bestGreen {
                course.subCourses[slot.sub].holes[slot.hole].features.append(green.id)
                assignedIDs.insert(green.id)
            }

            // Step 2: Walk tees forward along the centerline vector.
            // Start at the centerline start point. Find the closest unassigned tee.
            // After finding one, advance the search point to the farthest point of
            // that tee's polygon along the centerline direction. Repeat until no
            // more tees are found within the threshold and forward of the start.
            var searchPoint = cl.first!

            while true {
                var bestTee: Feature?
                var bestTeeDist = Double.greatestFiniteMagnitude
                for feature in features where feature.type == .tee && !assignedIDs.contains(feature.id) {
                    let centroid = feature.center
                    guard isForwardOfStart(point: centroid, centerline: cl) else { continue }
                    let lateralDist = distanceToPolyline(from: centroid, polyline: cl)
                    guard lateralDist <= thresholdMeters else { continue }
                    let dist = centroid.clLocation.distance(from: searchPoint.clLocation)
                    if dist < bestTeeDist {
                        bestTeeDist = dist
                        bestTee = feature
                    }
                }

                guard let tee = bestTee else { break }

                course.subCourses[slot.sub].holes[slot.hole].features.append(tee.id)
                assignedIDs.insert(tee.id)

                // Advance search point to the farthest vertex of this tee along the centerline direction
                searchPoint = farthestPointAlongCenterline(polygon: tee.polygon, centerline: cl)
            }

            // Step 3: Associate remaining features (fairways, bunkers, water, rough)
            // that are within 35 yards of the centerline and forward of the start.
            for feature in features where !assignedIDs.contains(feature.id) {
                guard isForwardOfStart(point: feature.center, centerline: cl) else { continue }
                if shouldAssociate(feature: feature, withCenterline: cl, threshold: thresholdMeters) {
                    course.subCourses[slot.sub].holes[slot.hole].features.append(feature.id)
                    assignedIDs.insert(feature.id)
                }
            }

            // Step 4: Assign tee names
            assignTeeNames(slot: slot, course: &course)
        }

        return assignedIDs
    }

    /// Returns the point in the polygon that is farthest along the centerline direction.
    /// Projects each vertex onto the centerline direction vector and picks the one with
    /// the largest projection value.
    private static func farthestPointAlongCenterline(
        polygon: [Coordinate],
        centerline: [Coordinate]
    ) -> Coordinate {
        let start = centerline.first!
        let end = centerline.last!
        let dx = end.longitude - start.longitude
        let dy = end.latitude - start.latitude

        var best = polygon[0]
        var bestProjection = -Double.greatestFiniteMagnitude
        for vertex in polygon {
            let px = vertex.longitude - start.longitude
            let py = vertex.latitude - start.latitude
            let projection = px * dx + py * dy
            if projection > bestProjection {
                bestProjection = projection
                best = vertex
            }
        }
        return best
    }

    /// For holes missing centerlines, synthesize a 2-point centerline by pairing
    /// the nearest unassigned tee (start) with the nearest unassigned green (end).
    private static func synthesizeCenterlines(
        for slots: [(sub: Int, hole: Int, global: Int)],
        features: [Feature],
        alreadyAssigned: Set<Int>,
        course: inout Course
    ) {
        let tees = features.filter { $0.type == .tee && !alreadyAssigned.contains($0.id) }
        let greens = features.filter { $0.type == .green && !alreadyAssigned.contains($0.id) }
        var usedTeeIDs: Set<Int> = []
        var usedGreenIDs: Set<Int> = []

        for slot in slots {
            var bestGreen: Feature?
            var bestGreenDist = Double.greatestFiniteMagnitude
            let ref = course.location.coordinate
            for green in greens where !usedGreenIDs.contains(green.id) {
                let dist = green.center.clLocation.distance(from: ref.clLocation)
                if dist < bestGreenDist {
                    bestGreenDist = dist
                    bestGreen = green
                }
            }

            let teeRef = bestGreen?.center ?? ref
            var bestTee: Feature?
            var bestTeeDist = Double.greatestFiniteMagnitude
            for tee in tees where !usedTeeIDs.contains(tee.id) {
                let dist = tee.center.clLocation.distance(from: teeRef.clLocation)
                if dist < bestTeeDist {
                    bestTeeDist = dist
                    bestTee = tee
                }
            }

            var centerline: [Coordinate] = []
            if let tee = bestTee {
                centerline.append(tee.center)
                usedTeeIDs.insert(tee.id)
            }
            if let green = bestGreen {
                centerline.append(green.center)
                usedGreenIDs.insert(green.id)
            }
            course.subCourses[slot.sub].holes[slot.hole].centerline = centerline
        }
    }

    /// Assign tee names for a single hole using distance-rank zipping or yardage clustering.
    private static func assignTeeNames(
        slot: (sub: Int, hole: Int, global: Int),
        course: inout Course
    ) {
        let metersPerYard = 0.9144
        let hole = course.subCourses[slot.sub].holes[slot.hole]
        guard !hole.yardages.isEmpty else { return }

        let holeFeatures = course.features(for: hole)
        guard let green = hole.green(from: holeFeatures) else { return }
        let greenCentroid = green.center

        let teeFeatures = holeFeatures.filter { $0.type == .tee }
        guard !teeFeatures.isEmpty else { return }

        var teeDistances: [(featureID: Int, yards: Double)] = []
        for tee in teeFeatures {
            let distMeters = tee.center.clLocation.distance(from: greenCentroid.clLocation)
            teeDistances.append((tee.id, distMeters / metersPerYard))
        }

        teeDistances.sort { $0.yards > $1.yards }
        let sortedYardages = hole.yardages.sorted { $0.value > $1.value }

        if teeDistances.count == sortedYardages.count {
            for (tee, entry) in zip(teeDistances, sortedYardages) {
                course.subCourses[slot.sub].holes[slot.hole].tees[entry.key] = tee.featureID
            }
        } else if teeDistances.count < sortedYardages.count {
            let clusters = clusterYardages(sortedYardages, into: teeDistances.count)
            for (i, cluster) in clusters.enumerated() {
                for (name, _) in cluster {
                    course.subCourses[slot.sub].holes[slot.hole].tees[name] = teeDistances[i].featureID
                }
            }
        } else {
            for (name, yards) in sortedYardages {
                var bestFeatureID: Int?
                var bestDiff = Double.greatestFiniteMagnitude
                for tee in teeDistances {
                    let diff = abs(tee.yards - Double(yards))
                    if diff < bestDiff {
                        bestDiff = diff
                        bestFeatureID = tee.featureID
                    }
                }
                if let featureID = bestFeatureID {
                    course.subCourses[slot.sub].holes[slot.hole].tees[name] = featureID
                }
            }
        }
    }

    /// Cluster a sorted (descending) array of yardage entries into `n` groups by splitting
    /// at the largest gaps between consecutive yardages.
    private static func clusterYardages(
        _ sortedYardages: [(key: String, value: Int)],
        into n: Int
    ) -> [[(key: String, value: Int)]] {
        guard n > 0, !sortedYardages.isEmpty else { return [] }
        guard n < sortedYardages.count else {
            return sortedYardages.map { [$0] }
        }

        var gaps: [(index: Int, gap: Int)] = []
        for i in 0..<(sortedYardages.count - 1) {
            let gap = sortedYardages[i].value - sortedYardages[i + 1].value
            gaps.append((i, gap))
        }
        gaps.sort { $0.gap > $1.gap }
        let splitIndices = gaps.prefix(n - 1).map(\.index).sorted()

        var clusters: [[(key: String, value: Int)]] = []
        var start = 0
        for splitIndex in splitIndices {
            clusters.append(Array(sortedYardages[start...(splitIndex)]))
            start = splitIndex + 1
        }
        clusters.append(Array(sortedYardages[start...]))
        return clusters
    }

    /// Returns true if `point` is not behind the centerline's start.
    /// Uses the dot product of (point - start) against the centerline direction (start → end).
    /// Points at or forward of the start (dot product >= 0) return true.
    /// Returns true if the centerline has fewer than 2 points (no direction to check).
    static func isForwardOfStart(point: Coordinate, centerline: [Coordinate]) -> Bool {
        guard centerline.count >= 2 else { return true }
        let start = centerline.first!
        let end = centerline.last!
        let dx = end.longitude - start.longitude
        let dy = end.latitude - start.latitude
        let px = point.longitude - start.longitude
        let py = point.latitude - start.latitude
        return (px * dx + py * dy) >= 0
    }

    /// Renumber OSM centerlines to match the course's sequential hole numbering (1-N).
    ///
    /// OSM data can have duplicate hole numbers (e.g., two sets of 1-9 for a 27-hole course).
    /// This method groups centerlines spatially into clusters (one per sub-course), matches
    /// each cluster to a sub-course by comparing centerline distances against scorecard
    /// yardages, then renumbers everything sequentially.
    ///
    /// If centerline numbers are already unique and match the course, this is a no-op.
    static func renumberCenterlines(
        in result: OverpassAPIClient.ParsedResult,
        for course: Course
    ) -> OverpassAPIClient.ParsedResult {
        let centerlines = result.centerlines
        let totalHoles = course.subCourses.flatMap(\.holes).count
        let uniqueNumbers = Set(centerlines.compactMap(\.holeNumber))

        // If numbers are already unique and cover all holes, no renumbering needed
        if uniqueNumbers.count == centerlines.count && uniqueNumbers.count == totalHoles {
            return result
        }

        guard !centerlines.isEmpty, !course.subCourses.isEmpty else { return result }

        // Step 1: Cluster centerlines spatially using their midpoint coordinates.
        // We need as many clusters as sub-courses.
        let targetClusterCount = course.subCourses.count
        let clusters = spatiallyClusterCenterlines(centerlines, into: targetClusterCount)

        // Step 2: Sort centerlines within each cluster by their original hole number
        let sortedClusters = clusters.map { cluster in
            cluster.sorted { a, b in
                (a.holeNumber ?? 0) < (b.holeNumber ?? 0)
            }
        }

        // Step 3: Match each cluster to the best sub-course by yardage pattern.
        // Compute the average centerline distance for each cluster, then compare
        // against the average yardage of each sub-course's longest tee.
        let metersPerYard = 0.9144
        var clusterDistances: [[Double]] = []
        for cluster in sortedClusters {
            let distances = cluster.map { cl -> Double in
                guard cl.coordinates.count >= 2 else { return 0 }
                let start = cl.coordinates.first!
                let end = cl.coordinates.last!
                return start.clLocation.distance(from: end.clLocation) / metersPerYard
            }
            clusterDistances.append(distances)
        }

        // For each sub-course, get the max tee yardages per hole (sorted by hole order)
        var subCourseYardages: [[Int]] = []
        for subCourse in course.subCourses {
            let yardages = subCourse.holes.map { hole in
                hole.yardages.values.max() ?? 0
            }
            subCourseYardages.append(yardages)
        }

        // Greedy best-fit matching: for each cluster, find the sub-course whose
        // yardage pattern is closest (by sum of squared differences)
        var usedSubCourses: Set<Int> = []
        var clusterToSubCourse: [Int: Int] = [:]

        for clusterIdx in sortedClusters.indices {
            var bestSubIdx = 0
            var bestScore = Double.greatestFiniteMagnitude

            for subIdx in course.subCourses.indices where !usedSubCourses.contains(subIdx) {
                // Clusters and sub-courses may have different hole counts; compare up to the minimum
                let count = min(clusterDistances[clusterIdx].count, subCourseYardages[subIdx].count)
                guard count > 0 else { continue }

                var score = 0.0
                for i in 0..<count {
                    let diff = clusterDistances[clusterIdx][i] - Double(subCourseYardages[subIdx][i])
                    score += diff * diff
                }
                score /= Double(count) // normalize by hole count

                if score < bestScore {
                    bestScore = score
                    bestSubIdx = subIdx
                }
            }

            clusterToSubCourse[clusterIdx] = bestSubIdx
            usedSubCourses.insert(bestSubIdx)
        }

        // Step 4: Renumber. Sub-courses are ordered by their index, so compute
        // the global hole offset for each sub-course and assign sequential numbers.
        var renumbered: [OverpassAPIClient.ParsedCenterline] = []
        for clusterIdx in sortedClusters.indices {
            guard let subIdx = clusterToSubCourse[clusterIdx] else { continue }

            // Compute global offset: sum of holes in all sub-courses before this one
            var globalOffset = 0
            for i in 0..<subIdx {
                globalOffset += course.subCourses[i].holes.count
            }

            for (holeIdx, centerline) in sortedClusters[clusterIdx].enumerated() {
                let globalNumber = globalOffset + holeIdx + 1
                renumbered.append(OverpassAPIClient.ParsedCenterline(
                    holeNumber: globalNumber,
                    coordinates: centerline.coordinates
                ))
            }
        }

        return OverpassAPIClient.ParsedResult(
            features: result.features,
            centerlines: renumbered,
            courseBoundary: result.courseBoundary
        )
    }

    /// Group centerlines into `n` spatial clusters based on their midpoint coordinates.
    /// Uses a simple iterative k-means approach in lat/lon space.
    private static func spatiallyClusterCenterlines(
        _ centerlines: [OverpassAPIClient.ParsedCenterline],
        into n: Int
    ) -> [[OverpassAPIClient.ParsedCenterline]] {
        guard n > 1, centerlines.count >= n else { return [centerlines] }

        // Compute midpoint for each centerline
        let midpoints: [Coordinate] = centerlines.map { cl in
            guard cl.coordinates.count >= 2 else {
                return cl.coordinates.first ?? Coordinate(latitude: 0, longitude: 0)
            }
            let start = cl.coordinates.first!
            let end = cl.coordinates.last!
            return Coordinate(
                latitude: (start.latitude + end.latitude) / 2,
                longitude: (start.longitude + end.longitude) / 2
            )
        }

        // Initialize centroids by picking evenly spaced centerlines sorted by latitude
        let sortedIndices = midpoints.indices.sorted { midpoints[$0].latitude < midpoints[$1].latitude }
        var centroids: [Coordinate] = []
        for i in 0..<n {
            let idx = sortedIndices[i * sortedIndices.count / n]
            centroids.append(midpoints[idx])
        }

        // Run k-means for a fixed number of iterations
        var assignments = [Int](repeating: 0, count: centerlines.count)
        for _ in 0..<20 {
            // Assign each centerline to nearest centroid
            for i in midpoints.indices {
                var bestCluster = 0
                var bestDist = Double.greatestFiniteMagnitude
                for c in 0..<n {
                    let dist = midpoints[i].clLocation.distance(from: centroids[c].clLocation)
                    if dist < bestDist {
                        bestDist = dist
                        bestCluster = c
                    }
                }
                assignments[i] = bestCluster
            }

            // Recompute centroids
            for c in 0..<n {
                let members = midpoints.indices.filter { assignments[$0] == c }
                guard !members.isEmpty else { continue }
                let avgLat = members.map { midpoints[$0].latitude }.reduce(0, +) / Double(members.count)
                let avgLon = members.map { midpoints[$0].longitude }.reduce(0, +) / Double(members.count)
                centroids[c] = Coordinate(latitude: avgLat, longitude: avgLon)
            }
        }

        // Build cluster arrays
        var clusters = [[OverpassAPIClient.ParsedCenterline]](repeating: [], count: n)
        for i in centerlines.indices {
            clusters[assignments[i]].append(centerlines[i])
        }
        return clusters
    }

    /// Determines if a feature should be associated with a hole based on three checks:
    /// 1. Does the centerline pass through the polygon? (handles large fairways/greens)
    /// 2. Is any polygon vertex within the threshold of the centerline? (handles offset features)
    /// 3. Is the polygon centroid within the threshold of the centerline? (handles small features)
    static func shouldAssociate(feature: Feature, withCenterline centerline: [Coordinate], threshold: Double) -> Bool {
        let polygon = feature.polygon
        guard !polygon.isEmpty, !centerline.isEmpty else { return false }

        for point in centerline {
            if PolygonGeometry.contains(point, in: polygon) {
                return true
            }
        }

        for vertex in polygon {
            if distanceToPolyline(from: vertex, polyline: centerline) < threshold {
                return true
            }
        }

        return distanceToPolyline(from: feature.center, polyline: centerline) < threshold
    }

    /// Minimum distance in meters from a point to a polyline (considering full line segments, not just vertices).
    static func distanceToPolyline(from point: Coordinate, polyline: [Coordinate]) -> Double {
        guard !polyline.isEmpty else { return .greatestFiniteMagnitude }
        guard polyline.count > 1 else {
            return point.clLocation.distance(from: polyline[0].clLocation)
        }

        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<(polyline.count - 1) {
            let dist = distanceToSegment(point: point, segStart: polyline[i], segEnd: polyline[i + 1])
            minDist = min(minDist, dist)
        }
        return minDist
    }

    /// Distance in meters from a point to a line segment, using projection onto the segment.
    private static func distanceToSegment(point: Coordinate, segStart: Coordinate, segEnd: Coordinate) -> Double {
        let dx = segEnd.longitude - segStart.longitude
        let dy = segEnd.latitude - segStart.latitude
        let lenSq = dx * dx + dy * dy

        if lenSq < 1e-20 {
            return point.clLocation.distance(from: segStart.clLocation)
        }

        let t = max(0, min(1, (
            (point.longitude - segStart.longitude) * dx +
            (point.latitude - segStart.latitude) * dy
        ) / lenSq))

        let nearest = Coordinate(
            latitude: segStart.latitude + t * dy,
            longitude: segStart.longitude + t * dx
        )
        return point.clLocation.distance(from: nearest.clLocation)
    }
}

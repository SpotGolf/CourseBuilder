import Foundation
import CoreLocation

enum OSMImporter {
    /// Apply parsed OSM data to a course using four phases:
    /// 1. Anchor greens 1:1 to holes via centerline endpoint proximity
    /// 2. Anchor tees to holes via centerline lateral proximity + directional filter
    /// 3. Associate remaining features via nearest centerline with directional filter
    /// 4. Assign tee names per-hole using distance-rank zipping or yardage clustering
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

        let holesWithCenterlines = holeSlots.filter { slot in
            !course.subCourses[slot.sub].holes[slot.hole].centerline.isEmpty
        }

        guard !holesWithCenterlines.isEmpty else {
            associateViaProximity(features: features, course: &course, holeSlots: holeSlots)
            return
        }

        let metersPerYard = 0.9144
        let thresholdMeters = 35.0 * metersPerYard

        // Phase 1: Anchor greens — each green goes to the hole whose centerline
        // endpoint is closest. Greedy 1:1 assignment (one green per hole).
        let greenFeatures = features.filter { $0.type == .green }
        var assignedGreenIDs: Set<Int> = []

        var holeCenterlineEnds: [(slot: (sub: Int, hole: Int, global: Int), end: Coordinate)] = []
        for slot in holesWithCenterlines {
            let cl = course.subCourses[slot.sub].holes[slot.hole].centerline
            if let end = cl.last {
                holeCenterlineEnds.append((slot, end))
            }
        }

        // Build all (hole, green, distance) candidates and sort by distance so the
        // closest pairs are matched first (prevents a far hole from stealing a green).
        var greenCandidates: [(holeIdx: Int, greenID: Int, dist: Double)] = []
        for (hIdx, holeEnd) in holeCenterlineEnds.enumerated() {
            for green in greenFeatures {
                let centroid = PolygonGeometry.centroid(of: green.polygon)
                let dist = centroid.clLocation.distance(from: holeEnd.end.clLocation)
                greenCandidates.append((hIdx, green.id, dist))
            }
        }
        greenCandidates.sort { $0.dist < $1.dist }

        var assignedHoleIndices: Set<Int> = []
        for candidate in greenCandidates {
            guard !assignedGreenIDs.contains(candidate.greenID),
                  !assignedHoleIndices.contains(candidate.holeIdx) else { continue }
            let slot = holeCenterlineEnds[candidate.holeIdx].slot
            course.subCourses[slot.sub].holes[slot.hole].features.append(candidate.greenID)
            assignedGreenIDs.insert(candidate.greenID)
            assignedHoleIndices.insert(candidate.holeIdx)
        }

        // Phase 2: Anchor tees — a tee must be within 35 yards laterally of the
        // centerline AND forward of its start. This allows tees spread along the
        // hole (e.g., junior tees 200 yards forward) while excluding adjacent holes.
        let teeFeatures = features.filter { $0.type == .tee }
        var assignedTeeIDs: Set<Int> = []

        for slot in holesWithCenterlines {
            let cl = course.subCourses[slot.sub].holes[slot.hole].centerline

            for tee in teeFeatures where !assignedTeeIDs.contains(tee.id) {
                let centroid = PolygonGeometry.centroid(of: tee.polygon)
                guard isForwardOfStart(point: centroid, centerline: cl) else { continue }
                let lateralDist = distanceToPolyline(from: centroid, polyline: cl)
                if lateralDist <= thresholdMeters {
                    course.subCourses[slot.sub].holes[slot.hole].features.append(tee.id)
                    assignedTeeIDs.insert(tee.id)
                }
            }
        }

        // Phase 3: Associate remaining features (fairways, bunkers, water, rough)
        // with the nearest hole's centerline, filtered by the directional check.
        let remainingFeatures = features.filter {
            !assignedGreenIDs.contains($0.id) && !assignedTeeIDs.contains($0.id)
        }
        associateRemainingFeatures(
            remainingFeatures,
            course: &course,
            holesWithCenterlines: holesWithCenterlines,
            threshold: thresholdMeters
        )

        // Phase 4: Assign tee names
        assignTeeNames(course: &course, holeSlots: holeSlots)
    }

    private static func associateViaProximity(
        features: [Feature],
        course: inout Course,
        holeSlots: [(sub: Int, hole: Int, global: Int)]
    ) {
        guard !holeSlots.isEmpty else { return }

        let tees = features.filter { $0.type == .tee }
        let greens = features.filter { $0.type == .green }

        for (i, slot) in holeSlots.enumerated() {
            if i < tees.count {
                course.subCourses[slot.sub].holes[slot.hole].features.append(tees[i].id)
            }
            if i < greens.count {
                course.subCourses[slot.sub].holes[slot.hole].features.append(greens[i].id)
            }

            let teeCentroid = (i < tees.count) ? PolygonGeometry.centroid(of: tees[i].polygon) : nil
            let greenCentroid = (i < greens.count) ? PolygonGeometry.centroid(of: greens[i].polygon) : nil
            var centerline: [Coordinate] = []
            if let t = teeCentroid { centerline.append(t) }
            if let g = greenCentroid { centerline.append(g) }
            course.subCourses[slot.sub].holes[slot.hole].centerline = centerline
        }

        let assigned = Set(tees.map(\.id) + greens.map(\.id))
        let remaining = features.filter { !assigned.contains($0.id) }

        for feature in remaining {
            let centroid = PolygonGeometry.centroid(of: feature.polygon)
            var bestSlot: (sub: Int, hole: Int, global: Int)?
            var bestDistance = Double.greatestFiniteMagnitude

            for slot in holeSlots {
                let cl = course.subCourses[slot.sub].holes[slot.hole].centerline
                guard !cl.isEmpty else { continue }
                let dist = distanceToPolyline(from: centroid, polyline: cl)
                if dist < bestDistance {
                    bestDistance = dist
                    bestSlot = slot
                }
            }

            if let slot = bestSlot {
                course.subCourses[slot.sub].holes[slot.hole].features.append(feature.id)
            }
        }
    }

    /// Phase 3: Associate non-anchor features with the nearest hole whose centerline
    /// is within the threshold, excluding features behind the centerline start.
    private static func associateRemainingFeatures(
        _ features: [Feature],
        course: inout Course,
        holesWithCenterlines: [(sub: Int, hole: Int, global: Int)],
        threshold: Double
    ) {
        for feature in features {
            let centroid = PolygonGeometry.centroid(of: feature.polygon)
            var bestSlot: (sub: Int, hole: Int, global: Int)?
            var bestDist = Double.greatestFiniteMagnitude

            for slot in holesWithCenterlines {
                let cl = course.subCourses[slot.sub].holes[slot.hole].centerline

                guard isForwardOfStart(point: centroid, centerline: cl) else { continue }

                if shouldAssociate(feature: feature, withCenterline: cl, threshold: threshold) {
                    let dist = distanceToPolyline(from: centroid, polyline: cl)
                    if dist < bestDist {
                        bestDist = dist
                        bestSlot = slot
                    }
                }
            }

            if let slot = bestSlot {
                course.subCourses[slot.sub].holes[slot.hole].features.append(feature.id)
            }
        }
    }

    /// Phase 4: Assign tee names to tee features on a per-hole basis.
    /// Only uses features already in `hole.features` (populated by Phase 2).
    ///
    /// When the number of tee polygons equals the number of tee names, both lists are sorted by
    /// distance/yardage and zipped directly. When they differ, tee names are clustered by yardage
    /// proximity into N groups (where N = polygon count), then each cluster is assigned to the
    /// matching-rank polygon.
    private static func assignTeeNames(
        course: inout Course,
        holeSlots: [(sub: Int, hole: Int, global: Int)]
    ) {
        let metersPerYard = 0.9144

        for slot in holeSlots {
            let hole = course.subCourses[slot.sub].holes[slot.hole]
            guard !hole.yardages.isEmpty else { continue }

            // Find green centroid for this hole
            let greenIDs = hole.features.filter { id in
                course.features.first { $0.id == id }?.type == .green
            }
            guard let greenID = greenIDs.first,
                  let green = course.features.first(where: { $0.id == greenID }) else { continue }
            let greenCentroid = PolygonGeometry.centroid(of: green.polygon)

            // Get tee features already associated with this hole
            let teeIDs = hole.features.filter { id in
                course.features.first { $0.id == id }?.type == .tee
            }
            guard !teeIDs.isEmpty else { continue }

            // Compute distance from each tee to the green centroid
            var teeDistances: [(featureID: Int, yards: Double)] = []
            for teeID in teeIDs {
                guard let feature = course.features.first(where: { $0.id == teeID }) else { continue }
                let teeCentroid = PolygonGeometry.centroid(of: feature.polygon)
                let distMeters = teeCentroid.clLocation.distance(from: greenCentroid.clLocation)
                teeDistances.append((teeID, distMeters / metersPerYard))
            }

            // Sort tees by distance descending (longest first) and yardages descending
            teeDistances.sort { $0.yards > $1.yards }
            let sortedYardages = hole.yardages.sorted { $0.value > $1.value }

            if teeDistances.count == sortedYardages.count {
                // Equal counts: zip by rank order — longest tee polygon gets highest yardage name
                for (tee, entry) in zip(teeDistances, sortedYardages) {
                    course.subCourses[slot.sub].holes[slot.hole].tees[entry.key] = tee.featureID
                }
            } else if teeDistances.count < sortedYardages.count {
                // More tee names than polygons: cluster yardages into N groups (N = polygon count)
                // by splitting at the largest gaps, then assign each cluster to the matching polygon.
                let clusters = clusterYardages(sortedYardages, into: teeDistances.count)
                for (i, cluster) in clusters.enumerated() {
                    for (name, _) in cluster {
                        course.subCourses[slot.sub].holes[slot.hole].tees[name] = teeDistances[i].featureID
                    }
                }
            } else {
                // More polygons than tee names (unusual): assign each name to the closest polygon
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
        // Direction vector (in lat/lon space)
        let dx = end.longitude - start.longitude
        let dy = end.latitude - start.latitude
        // Vector from start to point
        let px = point.longitude - start.longitude
        let py = point.latitude - start.latitude
        // Dot product
        return (px * dx + py * dy) >= 0
    }

    /// Determines if a feature should be associated with a hole based on three checks:
    /// 1. Does the centerline pass through the polygon? (handles large fairways/greens)
    /// 2. Is any polygon vertex within the threshold of the centerline? (handles offset features)
    /// 3. Is the polygon centroid within the threshold of the centerline? (handles small features)
    static func shouldAssociate(feature: Feature, withCenterline centerline: [Coordinate], threshold: Double) -> Bool {
        let polygon = feature.polygon
        guard !polygon.isEmpty, !centerline.isEmpty else { return false }

        // Check 1: Does any centerline point lie inside the polygon?
        for point in centerline {
            if PolygonGeometry.contains(point, in: polygon) {
                return true
            }
        }

        // Check 2: Is any polygon vertex within threshold of the centerline?
        for vertex in polygon {
            if distanceToPolyline(from: vertex, polyline: centerline) < threshold {
                return true
            }
        }

        // Check 3: Is the centroid within threshold of the centerline?
        let centroid = PolygonGeometry.centroid(of: polygon)
        return distanceToPolyline(from: centroid, polyline: centerline) < threshold
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
        // Work in lat/lon space for projection, then convert to meters
        let dx = segEnd.longitude - segStart.longitude
        let dy = segEnd.latitude - segStart.latitude
        let lenSq = dx * dx + dy * dy

        if lenSq < 1e-20 {
            return point.clLocation.distance(from: segStart.clLocation)
        }

        // Project point onto the line, clamped to [0, 1]
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

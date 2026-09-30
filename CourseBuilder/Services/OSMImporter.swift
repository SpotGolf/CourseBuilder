import Foundation
import CoreLocation
import CourseDataSwift

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

            // Step 1: Find the green whose polygon contains the centerline endpoint
            if let endpoint = cl.last {
                for feature in features where feature.type == .green && !assignedIDs.contains(feature.id) {
                    if PolygonGeometry.contains(endpoint, in: feature.polygon) {
                        course.subCourses[slot.sub].holes[slot.hole].features.append(feature.id)
                        assignedIDs.insert(feature.id)
                        break
                    }
                }
            }

            // Step 2: Walk tees forward along the centerline vector.
            // Start at the centerline start point. Find the closest unassigned tee.
            // After finding one, advance the search point to the farthest point of
            // that tee's polygon along the centerline direction. Repeat until no
            // more tees are found within the threshold and forward of the start.
            var searchPoint = cl.first!

            // First, grab any tee whose polygon contains the centerline start point.
            // This handles the back tee that the centerline originates from.
            if let startPoint = cl.first {
                for feature in features where feature.type == .tee && !assignedIDs.contains(feature.id) {
                    if PolygonGeometry.contains(startPoint, in: feature.polygon) {
                        course.subCourses[slot.sub].holes[slot.hole].features.append(feature.id)
                        assignedIDs.insert(feature.id)
                        searchPoint = farthestPointAlongCenterline(polygon: feature.polygon, centerline: cl)
                    }
                }
            }

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

    /// Assign tee names for a single hole by walking the tee boxes along the centerline.
    private static func assignTeeNames(
        slot: (sub: Int, hole: Int, global: Int),
        course: inout Course
    ) {
        let hole = course.subCourses[slot.sub].holes[slot.hole]
        for (name, featureID) in TeeGuesser.guessTees(for: hole, features: course.features) {
            course.subCourses[slot.sub].holes[slot.hole].tees[name] = featureID
        }
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

import Foundation
import CoreLocation

enum OSMImporter {
    /// Apply parsed OSM data to a course: assign feature IDs, associate features with holes,
    /// and set centerlines.
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

        // Associate each feature with every hole whose centerline is within 20 yards
        // of the feature's centroid. Features can be shared across holes.
        let thresholdMeters = 35.0 * 0.9144 // 35 yards in meters

        let holesWithCenterlines = holeSlots.filter { slot in
            !course.subCourses[slot.sub].holes[slot.hole].centerline.isEmpty
        }

        guard !holesWithCenterlines.isEmpty else {
            associateViaProximity(features: features, course: &course, holeSlots: holeSlots)
            return
        }

        for feature in features {
            for slot in holesWithCenterlines {
                let centerline = course.subCourses[slot.sub].holes[slot.hole].centerline
                if shouldAssociate(feature: feature, withCenterline: centerline, threshold: thresholdMeters) {
                    course.subCourses[slot.sub].holes[slot.hole].features.append(feature.id)
                }
            }
        }

        assignTeeNames(features: features, course: &course, holeSlots: holeSlots)
    }

    private static func associateViaProximity(
        features: [Feature],
        course: inout Course,
        holeSlots: [(sub: Int, hole: Int, global: Int)]
    ) {
        guard !holeSlots.isEmpty else { return }

        let tees = features.filter { $0.type == .tee }
        let greens = features.filter { $0.type == .green }

        // Assign one tee and one green per hole sequentially
        for (i, slot) in holeSlots.enumerated() {
            if i < tees.count {
                course.subCourses[slot.sub].holes[slot.hole].features.append(tees[i].id)
            }
            if i < greens.count {
                course.subCourses[slot.sub].holes[slot.hole].features.append(greens[i].id)
            }

            // Generate centerline from tee to green centroids
            let teeCentroid = (i < tees.count) ? PolygonGeometry.centroid(of: tees[i].polygon) : nil
            let greenCentroid = (i < greens.count) ? PolygonGeometry.centroid(of: greens[i].polygon) : nil
            var centerline: [Coordinate] = []
            if let t = teeCentroid { centerline.append(t) }
            if let g = greenCentroid { centerline.append(g) }
            course.subCourses[slot.sub].holes[slot.hole].centerline = centerline
        }

        // Assign remaining features (bunkers, water, fairways, rough) to nearest hole by centroid
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

    /// Assign tee names to tee features by matching tee-to-green distance against hole yardages.
    ///
    /// Finds tee polygons by proximity to the hole's centerline start point (which is at the tee
    /// complex) rather than relying solely on the initial centerline association, which can miss
    /// laterally-offset tee boxes. Uses a 100-yard radius from the centerline start.
    ///
    /// When the number of tee polygons equals the number of tee names, both lists are sorted by
    /// distance/yardage and zipped directly. When they differ, each tee name is assigned to the
    /// polygon whose measured distance best matches the scorecard yardage, allowing multiple
    /// names to share a polygon.
    private static func assignTeeNames(
        features: [Feature],
        course: inout Course,
        holeSlots: [(sub: Int, hole: Int, global: Int)]
    ) {
        let metersPerYard = 0.9144
        let teeThresholdMeters = 35.0 * metersPerYard
        let allTeeFeatures = features.filter { $0.type == .tee }

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

            // Find tee features near the hole's centerline (100-yard threshold),
            // falling back to those already in hole.features if no centerline exists
            let centerline = hole.centerline
            var teeDistances: [(featureID: Int, yards: Double)] = []
            for tee in allTeeFeatures {
                let teeCentroid = PolygonGeometry.centroid(of: tee.polygon)

                let include: Bool
                if !centerline.isEmpty {
                    let dist = distanceToPolyline(from: teeCentroid, polyline: centerline)
                    include = dist <= teeThresholdMeters
                } else {
                    include = hole.features.contains(tee.id)
                }

                if include {
                    let distMeters = teeCentroid.clLocation.distance(from: greenCentroid.clLocation)
                    teeDistances.append((tee.id, distMeters / metersPerYard))
                }
            }
            guard !teeDistances.isEmpty else { continue }

            // Ensure all found tee features are in hole.features
            for tee in teeDistances {
                if !course.subCourses[slot.sub].holes[slot.hole].features.contains(tee.featureID) {
                    course.subCourses[slot.sub].holes[slot.hole].features.append(tee.featureID)
                }
            }

            // Sort tees by distance descending (longest first) and yardages descending
            teeDistances.sort { $0.yards > $1.yards }
            let sortedYardages = hole.yardages.sorted { $0.value > $1.value }

            if teeDistances.count == sortedYardages.count {
                // Equal counts: zip by rank order — longest tee polygon gets highest yardage name
                for (tee, entry) in zip(teeDistances, sortedYardages) {
                    course.subCourses[slot.sub].holes[slot.hole].tees[entry.key] = tee.featureID
                }
            } else {
                // Unequal counts: assign each tee name to the polygon with the closest
                // measured distance, allowing multiple names per polygon
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

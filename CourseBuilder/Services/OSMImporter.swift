import Foundation

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

        // If we have centerlines from OSM, use them to associate features
        if !result.centerlines.isEmpty {
            associateViaCenterlines(result.centerlines, features: features, course: &course)
        } else {
            associateViaProximity(features: features, course: &course)
        }
    }

    private static func associateViaCenterlines(
        _ centerlines: [OverpassAPIClient.ParsedCenterline],
        features: [Feature],
        course: inout Course
    ) {
        for subIdx in course.subCourses.indices {
            for holeIdx in course.subCourses[subIdx].holes.indices {
                let hole = course.subCourses[subIdx].holes[holeIdx]

                // Calculate the global hole number (1-based across all subcourses)
                var globalNumber = hole.number
                for i in 0..<subIdx {
                    globalNumber += course.subCourses[i].holes.count
                }

                // Find matching centerline by global hole number or local number
                if let cl = centerlines.first(where: { $0.holeNumber == globalNumber })
                    ?? centerlines.first(where: { $0.holeNumber == hole.number && course.subCourses.count == 1 }) {
                    course.subCourses[subIdx].holes[holeIdx].centerline = cl.coordinates

                    // Associate features whose centroid is near the centerline
                    for feature in features {
                        let centroid = PolygonGeometry.centroid(of: feature.polygon)
                        if isNearCenterline(point: centroid, centerline: cl.coordinates, thresholdDegrees: 0.001) {
                            if !course.subCourses[subIdx].holes[holeIdx].featureIDs.contains(feature.id) {
                                course.subCourses[subIdx].holes[holeIdx].featureIDs.append(feature.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func associateViaProximity(features: [Feature], course: inout Course) {
        let tees = features.filter { $0.type == .tee }
        let greens = features.filter { $0.type == .green }

        for subIdx in course.subCourses.indices {
            for holeIdx in course.subCourses[subIdx].holes.indices {
                let allAssigned = course.subCourses.flatMap(\.holes).flatMap(\.featureIDs)

                if let nearestTee = tees.first(where: { !allAssigned.contains($0.id) }) {
                    course.subCourses[subIdx].holes[holeIdx].featureIDs.append(nearestTee.id)
                }
                if let nearestGreen = greens.first(where: { !allAssigned.contains($0.id) }) {
                    course.subCourses[subIdx].holes[holeIdx].featureIDs.append(nearestGreen.id)
                }

                // Generate centerline from tee to green centroids
                let holeFeatureIDs = course.subCourses[subIdx].holes[holeIdx].featureIDs
                let holeFeatures = holeFeatureIDs.compactMap { id in features.first { $0.id == id } }
                let teeCentroid = holeFeatures.first { $0.type == .tee }.map { PolygonGeometry.centroid(of: $0.polygon) }
                let greenCentroid = holeFeatures.first { $0.type == .green }.map { PolygonGeometry.centroid(of: $0.polygon) }

                var centerline: [Coordinate] = []
                if let t = teeCentroid { centerline.append(t) }
                if let g = greenCentroid { centerline.append(g) }
                course.subCourses[subIdx].holes[holeIdx].centerline = centerline
            }
        }
    }

    private static func isNearCenterline(point: Coordinate, centerline: [Coordinate], thresholdDegrees: Double) -> Bool {
        for coord in centerline {
            let dlat = abs(point.latitude - coord.latitude)
            let dlon = abs(point.longitude - coord.longitude)
            if dlat < thresholdDegrees && dlon < thresholdDegrees {
                return true
            }
        }
        for i in 0..<(centerline.count - 1) {
            let mid = Coordinate(
                latitude: (centerline[i].latitude + centerline[i + 1].latitude) / 2,
                longitude: (centerline[i].longitude + centerline[i + 1].longitude) / 2
            )
            let dlat = abs(point.latitude - mid.latitude)
            let dlon = abs(point.longitude - mid.longitude)
            if dlat < thresholdDegrees && dlon < thresholdDegrees {
                return true
            }
        }
        return false
    }
}

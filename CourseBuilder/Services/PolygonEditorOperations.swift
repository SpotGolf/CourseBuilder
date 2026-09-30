import CoreGraphics
import CoreLocation
import CourseDataSwift

struct DeletedFeatureRecord {
    let feature: Feature
    let featureIndex: Int
    let references: CourseIntegrity.FeatureReferences
}

enum PolygonEditorOperations {
    static func adjacentVertexIndex(current: Int?, count: Int, offset: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else {
            return offset > 0 ? 0 : count - 1
        }
        return (current + offset + count) % count
    }

    static func nearestVertexIndex(to point: Coordinate, in polygon: [Coordinate]) -> Int? {
        polygon.indices.min { lhs, rhs in
            polygon[lhs].clLocation.distance(from: point.clLocation)
                < polygon[rhs].clLocation.distance(from: point.clLocation)
        }
    }

    static func nearestEdge(
        to point: CGPoint,
        polygon: [Coordinate],
        maximumDistance: CGFloat = 10,
        convert: (CLLocationCoordinate2D) -> CGPoint?
    ) -> (insertionIndex: Int, point: CGPoint)? {
        guard polygon.count >= 3 else { return nil }

        var nearest: (insertionIndex: Int, point: CGPoint, distance: CGFloat)?
        for startIndex in polygon.indices {
            let endIndex = (startIndex + 1) % polygon.count
            guard let start = convert(polygon[startIndex].clCoordinate),
                  let end = convert(polygon[endIndex].clCoordinate) else { continue }

            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }

            let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
            let projected = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
            let distance = hypot(point.x - projected.x, point.y - projected.y)
            if nearest.map({ distance < $0.distance }) ?? true {
                nearest = (startIndex + 1, projected, distance)
            }
        }

        guard let nearest, nearest.distance <= maximumDistance else { return nil }
        return (nearest.insertionIndex, nearest.point)
    }

    @discardableResult
    static func applyElevation(_ elevation: Double, to coordinate: Coordinate, featureID: Int, in course: inout Course) -> Bool {
        guard let featureIndex = course.features.firstIndex(where: { $0.id == featureID }),
              let vertexIndex = course.features[featureIndex].polygon.firstIndex(where: {
                  $0.latitude == coordinate.latitude
                      && $0.longitude == coordinate.longitude
                      && $0.elevation == nil
              }) else { return false }
        course.features[featureIndex].polygon[vertexIndex].elevation = elevation
        return true
    }

    /// Sets the elevation on every centerline point of the hole that is at `coordinate` and has
    /// no elevation yet. Returns false if no such point exists, for example because it was moved again.
    @discardableResult
    static func applyCenterlineElevation(
        _ elevation: Double,
        to coordinate: Coordinate,
        subCourseIndex: Int,
        holeIndex: Int,
        in course: inout Course
    ) -> Bool {
        guard subCourseIndex < course.subCourses.count,
              holeIndex < course.subCourses[subCourseIndex].holes.count else { return false }
        var applied = false
        for index in course.subCourses[subCourseIndex].holes[holeIndex].centerline.indices {
            let point = course.subCourses[subCourseIndex].holes[holeIndex].centerline[index]
            if point.latitude == coordinate.latitude && point.longitude == coordinate.longitude && point.elevation == nil {
                course.subCourses[subCourseIndex].holes[holeIndex].centerline[index].elevation = elevation
                applied = true
            }
        }
        return applied
    }

    static func deleteFeature(id: Int, from course: inout Course) -> DeletedFeatureRecord? {
        guard let featureIndex = course.features.firstIndex(where: { $0.id == id }) else { return nil }
        let feature = course.features[featureIndex]
        let references = CourseIntegrity.removeReferences(to: id, from: &course)
        course.features.remove(at: featureIndex)
        return DeletedFeatureRecord(feature: feature, featureIndex: featureIndex, references: references)
    }

    @discardableResult
    static func restoreFeature(_ record: DeletedFeatureRecord, to course: inout Course) -> Bool {
        guard !course.features.contains(where: { $0.id == record.feature.id }) else { return false }
        course.features.insert(record.feature, at: min(record.featureIndex, course.features.count))
        CourseIntegrity.restoreReferences(record.references, to: record.feature.id, in: &course)
        return true
    }
}

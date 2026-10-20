import CoreGraphics
import CoreLocation
import CourseDataSwift

struct DeletedFeatureRecord {
    let feature: Feature
    let featureIndex: Int
    let references: CourseIntegrity.FeatureReferences
}

/// One change to the course's features that Cmd+Z can reverse.
enum FeatureUndoRecord {
    case deleted(DeletedFeatureRecord)
    case replacedPolygon(featureID: Int, oldPolygon: [Coordinate])
    case added(featureID: Int)
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

    /// Adds a feature with the next free ID to the course and, when the indexes are valid, to that hole.
    @discardableResult
    static func addFeature(
        type: FeatureType,
        polygon: [Coordinate],
        subCourseIndex: Int,
        holeIndex: Int,
        to course: inout Course
    ) -> Feature {
        let feature = Feature(id: course.nextFeatureID, type: type, polygon: polygon)
        course.features.append(feature)
        if course.subCourses.indices.contains(subCourseIndex),
           course.subCourses[subCourseIndex].holes.indices.contains(holeIndex) {
            course.subCourses[subCourseIndex].holes[holeIndex].features.append(feature.id)
        }
        return feature
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

    /// Reverses one recorded change. Returns false if the course no longer matches the record.
    @discardableResult
    static func undo(_ record: FeatureUndoRecord, in course: inout Course) -> Bool {
        switch record {
        case .deleted(let deleted):
            return restoreFeature(deleted, to: &course)
        case .replacedPolygon(let featureID, let oldPolygon):
            guard let index = course.features.firstIndex(where: { $0.id == featureID }) else { return false }
            course.features[index].polygon = oldPolygon
            return true
        case .added(let featureID):
            return deleteFeature(id: featureID, from: &course) != nil
        }
    }
}

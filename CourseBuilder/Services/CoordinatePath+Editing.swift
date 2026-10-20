import CourseDataSwift

/// Editing operations for paths. A path's points can't be changed in place, so each one rebuilds
/// the path.
extension CoordinatePath {
    mutating func insert(_ coordinate: Coordinate, at index: Int) {
        var points = Array(self)
        points.insert(coordinate, at: index)
        self = CoordinatePath(points)
    }

    mutating func remove(at index: Int) {
        var points = Array(self)
        points.remove(at: index)
        self = CoordinatePath(points)
    }

    mutating func replace(at index: Int, with coordinate: Coordinate) {
        var points = Array(self)
        points[index] = coordinate
        self = CoordinatePath(points)
    }
}

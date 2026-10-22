import CourseDataSwift

extension FeatureType {
    /// The types drawn as closed shapes. A centerline is an open line that is drawn and
    /// edited on its own, not as a polygon feature.
    static let polygonTypes: [FeatureType] = allCases.filter { $0 != .centerline }
}

extension Course {
    /// The points of the hole's centerline, or an empty path if it has none.
    func centerlinePath(for hole: Hole) -> CoordinatePath {
        hole.centerline(from: features)?.polygon ?? []
    }

    /// The IDs of every hole's centerline feature.
    var centerlineFeatureIDs: Set<Int> {
        Set(subCourses.flatMap(\.holes).compactMap(\.centerline))
    }

    /// Replaces a hole's centerline and its OSM ID. Adds a centerline feature if the hole has
    /// none. An empty path removes the hole's centerline feature.
    mutating func setCenterline(_ path: CoordinatePath, osmID: String? = nil, subCourseIndex: Int, holeIndex: Int) {
        guard subCourses.indices.contains(subCourseIndex),
              subCourses[subCourseIndex].holes.indices.contains(holeIndex) else { return }
        let existingID = subCourses[subCourseIndex].holes[holeIndex].centerline
        let existingIndex = existingID.flatMap { id in features.firstIndex { $0.id == id } }

        if path.isEmpty {
            if let existingIndex {
                features.remove(at: existingIndex)
            }
            subCourses[subCourseIndex].holes[holeIndex].centerline = nil
        } else if let existingIndex {
            features[existingIndex].polygon = path
            features[existingIndex].osmID = osmID
        } else {
            let feature = Feature(id: nextFeatureID, type: .centerline, polygon: path, osmID: osmID)
            features.append(feature)
            subCourses[subCourseIndex].holes[holeIndex].centerline = feature.id
        }
    }

    /// Changes the points of a hole's existing centerline in place, keeping its OSM ID.
    /// Does nothing if the hole has no centerline.
    mutating func updateCenterline(subCourseIndex: Int, holeIndex: Int, _ body: (inout CoordinatePath) -> Void) {
        guard subCourses.indices.contains(subCourseIndex),
              subCourses[subCourseIndex].holes.indices.contains(holeIndex),
              let id = subCourses[subCourseIndex].holes[holeIndex].centerline,
              let index = features.firstIndex(where: { $0.id == id }) else { return }
        body(&features[index].polygon)
    }
}

import CourseDataSwift

struct CourseIntegrity {
    struct FeatureAssociation {
        let subCourseIndex: Int
        let holeIndex: Int
        let featureIndex: Int
    }

    struct TeeAssignment {
        let subCourseIndex: Int
        let holeIndex: Int
        let teeName: String
    }

    struct FeatureReferences {
        let featureAssociations: [FeatureAssociation]
        let teeAssignments: [TeeAssignment]
    }

    struct RepairReport: Equatable {
        let removedFeatureReferences: Int
        let removedTeeAssignments: Int
        let removedYardages: Int
        let removedSubCourseTees: Int
        let removedComboTees: Int
        let actions: [String]

        init(
            removedFeatureReferences: Int,
            removedTeeAssignments: Int,
            removedYardages: Int = 0,
            removedSubCourseTees: Int = 0,
            removedComboTees: Int = 0,
            actions: [String] = []
        ) {
            self.removedFeatureReferences = removedFeatureReferences
            self.removedTeeAssignments = removedTeeAssignments
            self.removedYardages = removedYardages
            self.removedSubCourseTees = removedSubCourseTees
            self.removedComboTees = removedComboTees
            self.actions = actions
        }

        var madeChanges: Bool {
            !actions.isEmpty
        }
    }

    static func validateCourse(_ course: Course) -> [String] {
        var warnings: [String] = []
        var holeOffset = 0

        for subCourse in course.subCourses {
            for hole in subCourse.holes {
                let holeLabel = "Hole \(holeOffset + hole.number)"
                let holeFeatures = course.features(for: hole)

                if !holeFeatures.contains(where: { $0.type == .green }) {
                    warnings.append("\(holeLabel): missing green polygon")
                }

                if hole.par > 3 && !holeFeatures.contains(where: { $0.type == .fairway }) {
                    warnings.append("\(holeLabel): missing fairway polygon")
                }

                if !holeFeatures.contains(where: { $0.type == .tee }) {
                    warnings.append("\(holeLabel): missing tee polygon")
                }

                if hole.centerline.isEmpty {
                    warnings.append("\(holeLabel): missing centerline")
                }

                for teeName in hole.yardages.keys where hole.tees[teeName] == nil {
                    warnings.append("\(holeLabel): tee \"\(teeName)\" has yardage but no polygon assigned")
                }

                for (teeName, featureID) in hole.tees where course.findFeature(id: featureID) == nil {
                    warnings.append("\(holeLabel): tee \"\(teeName)\" references missing feature #\(featureID)")
                }

                for featureID in hole.features where course.findFeature(id: featureID) == nil {
                    warnings.append("\(holeLabel): references missing feature #\(featureID)")
                }

                for combo in course.comboTees {
                    guard let teeName = hole.comboTees[combo.name] else {
                        warnings.append("\(holeLabel): combo tee \"\(combo.name)\" has no tee picked")
                        continue
                    }
                    if !combo.tees.contains(teeName) {
                        warnings.append("\(holeLabel): combo tee \"\(combo.name)\" plays from \"\(teeName)\", which is not part of the combo")
                    } else if hole.tees[teeName] == nil {
                        warnings.append("\(holeLabel): combo tee \"\(combo.name)\" plays from \"\(teeName)\", which has no polygon assigned")
                    }
                }

                for comboName in hole.comboTees.keys.sorted() where !course.comboTees.contains(where: { $0.name == comboName }) {
                    warnings.append("\(holeLabel): references undefined combo tee \"\(comboName)\"")
                }
            }
            holeOffset += subCourse.holes.count
        }

        let teeNames = Set(course.tees.map(\.name))
        for combo in course.comboTees {
            for teeName in combo.tees where !teeNames.contains(teeName) {
                warnings.append("Combo tee \"\(combo.name)\" uses undefined tee \"\(teeName)\"")
            }
        }

        let assignedFeatureIDs = Set(course.subCourses.flatMap(\.holes).flatMap(\.features))
        let unassignedFeatures = course.features.filter { !assignedFeatureIDs.contains($0.id) }
        if !unassignedFeatures.isEmpty {
            let ids = unassignedFeatures.map { "#\($0.id)" }.joined(separator: ", ")
            warnings.append("\(unassignedFeatures.count) unassigned feature(s): \(ids)")
        }

        return warnings
    }

    @discardableResult
    static func cleanup(_ course: inout Course) -> RepairReport {
        let validFeatureIDs = Set(course.features.map(\.id))
        let validTeeNames = Set(course.tees.map(\.name))
        var removedFeatureReferences = 0
        var removedComboTees = 0
        var removedTeeAssignments = 0
        var removedYardages = 0
        var removedSubCourseTees = 0
        var actions: [String] = []

        for combo in course.comboTees where combo.tees.contains(where: { !validTeeNames.contains($0) }) {
            course.comboTees.removeAll { $0.name == combo.name }
            removedComboTees += 1
            actions.append("Removed combo tee \"\(combo.name)\" because it uses an undefined tee")
        }
        let validCombos = Dictionary(course.comboTees.map { ($0.name, $0.tees) }, uniquingKeysWith: { first, _ in first })

        for subCourseIndex in course.subCourses.indices {
            let subCourseName = course.subCourses[subCourseIndex].name
            for comboName in course.subCourses[subCourseIndex].comboTees.keys.sorted() where validCombos[comboName] == nil {
                course.subCourses[subCourseIndex].comboTees.removeValue(forKey: comboName)
                removedComboTees += 1
                actions.append("\(subCourseName): removed metadata for undefined combo tee \"\(comboName)\"")
            }
            let subCourseTeeNames = course.subCourses[subCourseIndex].tees.keys.sorted()
            for teeName in subCourseTeeNames where !validTeeNames.contains(teeName) {
                course.subCourses[subCourseIndex].tees.removeValue(forKey: teeName)
                removedSubCourseTees += 1
                actions.append("\(subCourseName): removed metadata for undefined tee \"\(teeName)\"")
            }

            for holeIndex in course.subCourses[subCourseIndex].holes.indices {
                let holeNumber = course.subCourses[subCourseIndex].holes[holeIndex].number
                let featureIDs = course.subCourses[subCourseIndex].holes[holeIndex].features
                for featureID in featureIDs where !validFeatureIDs.contains(featureID) {
                    actions.append("Hole \(holeNumber): removed missing feature reference #\(featureID)")
                    removedFeatureReferences += 1
                }
                course.subCourses[subCourseIndex].holes[holeIndex].features.removeAll {
                    !validFeatureIDs.contains($0)
                }

                let yardageTeeNames = course.subCourses[subCourseIndex].holes[holeIndex].yardages.keys.sorted()
                for teeName in yardageTeeNames where !validTeeNames.contains(teeName) {
                    course.subCourses[subCourseIndex].holes[holeIndex].yardages.removeValue(forKey: teeName)
                    removedYardages += 1
                    actions.append("Hole \(holeNumber): removed yardage for undefined tee \"\(teeName)\"")
                }

                let teeAssignments = course.subCourses[subCourseIndex].holes[holeIndex].tees
                for teeName in teeAssignments.keys.sorted() {
                    guard let featureID = teeAssignments[teeName] else { continue }
                    if !validTeeNames.contains(teeName) {
                        actions.append("Hole \(holeNumber): removed assignment for undefined tee \"\(teeName)\"")
                        removedTeeAssignments += 1
                    } else if !validFeatureIDs.contains(featureID) {
                        actions.append("Hole \(holeNumber): removed tee \"\(teeName)\" assignment to missing feature #\(featureID)")
                        removedTeeAssignments += 1
                    }
                }
                course.subCourses[subCourseIndex].holes[holeIndex].tees = teeAssignments.filter {
                    validTeeNames.contains($0.key) && validFeatureIDs.contains($0.value)
                }

                let comboAssignments = course.subCourses[subCourseIndex].holes[holeIndex].comboTees
                for comboName in comboAssignments.keys.sorted() {
                    guard let teeName = comboAssignments[comboName] else { continue }
                    if let comboTees = validCombos[comboName] {
                        guard !comboTees.contains(teeName) else { continue }
                        actions.append("Hole \(holeNumber): removed combo tee \"\(comboName)\" assignment to \"\(teeName)\", which is not part of the combo")
                    } else {
                        actions.append("Hole \(holeNumber): removed assignment for undefined combo tee \"\(comboName)\"")
                    }
                    course.subCourses[subCourseIndex].holes[holeIndex].comboTees.removeValue(forKey: comboName)
                    removedComboTees += 1
                }
            }
        }

        return RepairReport(
            removedFeatureReferences: removedFeatureReferences,
            removedTeeAssignments: removedTeeAssignments,
            removedYardages: removedYardages,
            removedSubCourseTees: removedSubCourseTees,
            removedComboTees: removedComboTees,
            actions: actions
        )
    }

    @discardableResult
    static func repairDanglingReferences(in course: inout Course) -> RepairReport {
        cleanup(&course)
    }

    @discardableResult
    static func renameTee(at index: Int, to newName: String, in course: inout Course) -> Bool {
        guard course.tees.indices.contains(index) else { return false }
        let oldName = course.tees[index].name
        guard newName != oldName else { return true }
        guard !newName.isEmpty,
              !course.tees.enumerated().contains(where: { $0.offset != index && $0.element.name == newName }),
              !course.comboTees.contains(where: { $0.name == newName }) else {
            return false
        }

        course.tees[index].name = newName
        for comboIndex in course.comboTees.indices {
            course.comboTees[comboIndex].tees = course.comboTees[comboIndex].tees.map { $0 == oldName ? newName : $0 }
        }
        for subCourseIndex in course.subCourses.indices {
            moveValue(from: oldName, to: newName, in: &course.subCourses[subCourseIndex].tees)
            for holeIndex in course.subCourses[subCourseIndex].holes.indices {
                moveValue(
                    from: oldName,
                    to: newName,
                    in: &course.subCourses[subCourseIndex].holes[holeIndex].yardages
                )
                moveValue(
                    from: oldName,
                    to: newName,
                    in: &course.subCourses[subCourseIndex].holes[holeIndex].tees
                )
                course.subCourses[subCourseIndex].holes[holeIndex].comboTees =
                    course.subCourses[subCourseIndex].holes[holeIndex].comboTees.mapValues { $0 == oldName ? newName : $0 }
            }
        }
        return true
    }

    /// What uses a tee: the number of holes with a tee box assigned to it and the combo tees made from it.
    struct TeeUsage: Equatable {
        let holesWithTeeBox: Int
        let comboTees: [String]

        var isInUse: Bool {
            holesWithTeeBox > 0 || !comboTees.isEmpty
        }
    }

    static func usage(ofTeeNamed teeName: String, in course: Course) -> TeeUsage {
        TeeUsage(
            holesWithTeeBox: course.subCourses.flatMap(\.holes).filter { $0.tees[teeName] != nil }.count,
            comboTees: course.comboTees.filter { $0.tees.contains(teeName) }.map(\.name)
        )
    }

    static func removeTee(at index: Int, from course: inout Course) {
        guard course.tees.indices.contains(index) else { return }
        let teeName = course.tees.remove(at: index).name
        // A combo tee cannot be played without all of its tees.
        for combo in course.comboTees where combo.tees.contains(teeName) {
            ComboTeeBuilder.delete(comboNamed: combo.name, from: &course)
        }
        for subCourseIndex in course.subCourses.indices {
            course.subCourses[subCourseIndex].tees.removeValue(forKey: teeName)
            for holeIndex in course.subCourses[subCourseIndex].holes.indices {
                course.subCourses[subCourseIndex].holes[holeIndex].yardages.removeValue(forKey: teeName)
                course.subCourses[subCourseIndex].holes[holeIndex].tees.removeValue(forKey: teeName)
            }
        }
    }

    private static func moveValue<Value>(from oldKey: String, to newKey: String, in dictionary: inout [String: Value]) {
        guard let value = dictionary.removeValue(forKey: oldKey) else { return }
        dictionary[newKey] = value
    }

    static func removeReferences(to featureID: Int, from course: inout Course) -> FeatureReferences {
        var featureAssociations: [FeatureAssociation] = []
        var teeAssignments: [TeeAssignment] = []

        for subCourseIndex in course.subCourses.indices {
            for holeIndex in course.subCourses[subCourseIndex].holes.indices {
                let hole = course.subCourses[subCourseIndex].holes[holeIndex]
                featureAssociations.append(contentsOf: hole.features.enumerated().compactMap { index, id in
                    id == featureID
                        ? FeatureAssociation(
                            subCourseIndex: subCourseIndex,
                            holeIndex: holeIndex,
                            featureIndex: index
                        )
                        : nil
                })
                teeAssignments.append(contentsOf: hole.tees.compactMap { teeName, id in
                    id == featureID
                        ? TeeAssignment(
                            subCourseIndex: subCourseIndex,
                            holeIndex: holeIndex,
                            teeName: teeName
                        )
                        : nil
                })

                course.subCourses[subCourseIndex].holes[holeIndex].features.removeAll { $0 == featureID }
                course.subCourses[subCourseIndex].holes[holeIndex].tees = hole.tees.filter { $0.value != featureID }
            }
        }

        return FeatureReferences(
            featureAssociations: featureAssociations,
            teeAssignments: teeAssignments
        )
    }

    static func restoreReferences(_ references: FeatureReferences, to featureID: Int, in course: inout Course) {
        for association in references.featureAssociations {
            guard course.subCourses.indices.contains(association.subCourseIndex),
                  course.subCourses[association.subCourseIndex].holes.indices.contains(association.holeIndex) else {
                continue
            }
            let featureCount = course.subCourses[association.subCourseIndex].holes[association.holeIndex].features.count
            course.subCourses[association.subCourseIndex].holes[association.holeIndex].features.insert(
                featureID,
                at: min(association.featureIndex, featureCount)
            )
        }

        for assignment in references.teeAssignments {
            guard course.subCourses.indices.contains(assignment.subCourseIndex),
                  course.subCourses[assignment.subCourseIndex].holes.indices.contains(assignment.holeIndex) else {
                continue
            }
            course.subCourses[assignment.subCourseIndex].holes[assignment.holeIndex].tees[assignment.teeName] = featureID
        }
    }
}

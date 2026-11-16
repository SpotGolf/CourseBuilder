import SwiftUI
import CourseDataSwift

/// Assigns the groups of holes found in OpenStreetMap to a course's sub-courses.
///
/// The list on the left has one row per group, with the sub-course it goes to. The map on the
/// right draws every hole's line in its group's color. Click a group or a line to select it.
/// A selected line can be moved to another group.
struct SubCourseAssignmentView: View {
    let subCourseNames: [String]
    @Binding var groups: [CenterlineGroup]

    @AppStorage("imageryLayer") private var imageryLayer: ImageryLayer = .esri
    @State private var camera = MapCamera()
    @State private var tileLoader = TileLoader()
    @State private var selectedGroup: Int?
    /// An index into the selected group's centerlines.
    @State private var selectedCenterline: Int?
    @State private var hasFitMap = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 360)
            map
                .frame(minWidth: 380, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Assign Holes to Sub-Courses")
                .font(.headline)
                .padding(8)

            Text("OpenStreetMap has this course. Select a group to see its holes on the map, then pick its sub-course. Remove groups that are not part of this course.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            Text("A hole in the wrong group? Click its line on the map, then move it to the group for its sub-course.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        groupRow(index: index, group: group)
                    }
                }
                .padding(8)
            }

            if let groupIndex = selectedGroup,
               let centerlineIndex = selectedCenterline,
               groups.indices.contains(groupIndex),
               groups[groupIndex].centerlines.indices.contains(centerlineIndex) {
                Divider()
                centerlineInspector(groupIndex: groupIndex, centerlineIndex: centerlineIndex)
            }
        }
        .background(Color(.windowBackgroundColor))
    }

    private func groupRow(index: Int, group: CenterlineGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(CenterlineGroup.color(for: index))
                    .frame(width: 10, height: 10)
                Text(group.label)
                    .font(.body.bold())
                Spacer()
                Button {
                    removeGroup(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Leave these holes out of the course")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                selectGroup(selectedGroup == index ? nil : index)
            }

            Picker("Sub-Course", selection: Binding(
                get: { groups[index].assignedSubCourseIndex },
                set: { groups[index].assignedSubCourseIndex = $0 }
            )) {
                Text("Select...").tag(nil as Int?)
                ForEach(Array(subCourseNames.enumerated()), id: \.offset) { subCourseIndex, name in
                    Text(name).tag(subCourseIndex as Int?)
                }
            }
            .labelsHidden()
        }
        .padding(8)
        .background(selectedGroup == index ? CenterlineGroup.color(for: index).opacity(0.15) : Color.clear)
        .cornerRadius(6)
    }

    /// Moves the selected hole to another group.
    private func centerlineInspector(groupIndex: Int, centerlineIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hole \(groups[groupIndex].centerlines[centerlineIndex].holeNumber ?? 0)")
                .font(.subheadline.bold())
            Text("Currently in: \(groups[groupIndex].label)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Move to", selection: Binding(
                get: { groupIndex },
                set: { moveCenterline(fromGroup: groupIndex, index: centerlineIndex, toGroup: $0) }
            )) {
                ForEach(groups.indices, id: \.self) { index in
                    Text(groups[index].label).tag(index)
                }
            }
        }
        .padding(8)
    }

    // MARK: - Map

    private var map: some View {
        TileMapView(camera: camera, loader: tileLoader, layer: imageryLayer) {
            MapShapesLayer(camera: camera, shapes: shapes)
            HoleNumbersLayer(camera: camera, groups: groups)
        }
        .simultaneousGesture(
            SpatialTapGesture().onEnded { tap in
                selectCenterline(at: camera.projection.coordinate(at: tap.location))
            }
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Shows every hole once the map knows its size.
            guard !hasFitMap, size.width > 0, size.height > 0 else { return }
            hasFitMap = true
            camera.size = size
            camera.fit(groups.flatMap(\.centerlines).flatMap(\.coordinates))
        }
    }

    /// Every hole's line. The selected group's lines are thicker, and the selected line is white.
    private var shapes: [MapShape] {
        var shapes: [MapShape] = []
        for (groupIndex, group) in groups.enumerated() {
            let isGroupSelected = selectedGroup == groupIndex
            let color = CenterlineGroup.color(for: groupIndex)
            for (centerlineIndex, centerline) in group.centerlines.enumerated() {
                let isSelected = isGroupSelected && selectedCenterline == centerlineIndex
                shapes.append(MapShape(
                    kind: .polyline,
                    coordinates: centerline.coordinates,
                    stroke: isSelected ? .white : color,
                    lineWidth: isSelected ? 5 : (isGroupSelected ? 4 : 2)
                ))
            }
        }
        return shapes
    }

    // MARK: - Actions

    /// Selects a group and moves the map to show its holes.
    private func selectGroup(_ index: Int?) {
        selectedGroup = index
        selectedCenterline = nil
        if let index, groups.indices.contains(index) {
            camera.fit(groups[index].centerlines.flatMap(\.coordinates))
        }
    }

    /// Selects the hole line nearest the point, if one is within about 50 meters.
    private func selectCenterline(at point: Coordinate) {
        var best: (group: Int, centerline: Int, distance: Double)?
        for (groupIndex, group) in groups.enumerated() {
            for (centerlineIndex, centerline) in group.centerlines.enumerated() {
                let distance = OSMImporter.distanceToPolyline(from: point, polyline: CoordinatePath(centerline.coordinates))
                if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (groupIndex, centerlineIndex, distance)
                }
            }
        }
        if let best, best.distance < 50 {
            selectedGroup = best.group
            selectedCenterline = best.centerline
        } else {
            selectedCenterline = nil
        }
    }

    private func moveCenterline(fromGroup: Int, index: Int, toGroup: Int) {
        guard fromGroup != toGroup,
              groups.indices.contains(fromGroup),
              groups.indices.contains(toGroup),
              groups[fromGroup].centerlines.indices.contains(index) else { return }
        let centerline = groups[fromGroup].centerlines.remove(at: index)
        groups[toGroup].centerlines.append(centerline)
        groups.relabel()
        selectedGroup = toGroup
        selectedCenterline = nil
    }

    private func removeGroup(at index: Int) {
        guard groups.indices.contains(index) else { return }
        groups.removeGroup(at: index)
        selectedGroup = nil
        selectedCenterline = nil
    }
}

/// Draws each hole's OpenStreetMap number where its line starts.
private struct HoleNumbersLayer: View {
    let camera: MapCamera
    let groups: [CenterlineGroup]

    var body: some View {
        let projection = camera.projection
        ZStack(alignment: .topLeading) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                ForEach(Array(group.centerlines.enumerated()), id: \.offset) { _, centerline in
                    if let number = centerline.holeNumber, let start = centerline.coordinates.first {
                        Text("\(number)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(CenterlineGroup.color(for: groupIndex), in: Capsule())
                            .position(projection.point(for: start))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("Three nines") {
    @Previewable @State var groups: [CenterlineGroup] = (0..<3).map { row in
        CenterlineGroup(
            label: "9 holes (group \(row + 1))",
            centerlines: (1...9).map { number in
                let lat = 39.925 + Double(row) * 0.004
                let lon = -105.115 + Double(number) * 0.0015
                return OverpassAPIClient.ParsedCenterline(
                    holeNumber: number,
                    coordinates: [Coordinate(lat: lat, lon: lon), Coordinate(lat: lat + 0.003, lon: lon + 0.0005)]
                )
            },
            assignedSubCourseIndex: row == 0 ? 0 : nil
        )
    }
    SubCourseAssignmentView(subCourseNames: ["Eldorado", "Vista", "Sunshine"], groups: $groups)
        .frame(width: 1000, height: 640)
}

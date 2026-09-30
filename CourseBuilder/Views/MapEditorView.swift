import SwiftUI
import MapKit
import CoreLocation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "MapEditor")

enum MapStyleMode: String, CaseIterable {
    case satellite = "Satellite"
    case hybrid = "Hybrid"
    case standard = "Standard"

    var next: MapStyleMode {
        let all = Self.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }
}

struct MapEditorView: View {
    @Binding var course: Course

    // Selection state
    @State private var selectedSubCourseIndex: Int = 0
    @State private var selectedHoleIndex: Int = 0
    @State private var selectedFeatureID: Int?
    @State private var selectedVertexIndex: Int?
    @State private var isEditingFeature = false
    @State private var isCenterlineSelected = false
    @State private var isEditingCenterline = false
    @State private var selectedCenterlineVertexIndex: Int?

    // Drawing state
    @State private var drawingVertices: [Coordinate] = []
    @State private var selectedDrawingVertexIndex: Int?
    @State private var pendingFeatureType: FeatureType = .fairway
    @State private var isCompletingPolygon = false

    // Map state
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapStyleMode: MapStyleMode = .satellite
    private var mapStyle: MapStyle {
        switch mapStyleMode {
        case .satellite: .imagery(elevation: .realistic)
        case .hybrid: .hybrid(elevation: .realistic)
        case .standard: .standard
        }
    }
    @State private var activeTool: ToolMode = .select
    @State private var statusMessage = ""
    @State private var statusTask: Task<Void, Never>?
    @State private var isDraggingVertex = false
    @State private var dragOffset: CGSize = .zero
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapViewSize: CGSize = .zero
    @State private var hoveredMapCoordinate: Coordinate?
    @FocusState private var isMapFocused: Bool

    // OSM import state
    @State private var isImportingOSM = false
    @State private var osmImportStatus = ""
    @State private var pendingOSMResult: OverpassAPIClient.ParsedResult?
    @State private var centerlineGroups: [CenterlineGroup] = []
    @State private var selectedMappingGroup: Int?
    @State private var selectedMappingCenterline: Int? // index into the selected group's centerlines
    private var isMappingMode: Bool { pendingOSMResult != nil }

    // Delete confirmation
    @State private var featureToDelete: Int?
    @State private var deletedFeatureRecords: [DeletedFeatureRecord] = []

    // Sidebar list heights
    @State private var holesCollapsed = false
    @State private var featuresCollapsed = false
    @State private var unassociatedCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HSplitView {
                if pendingOSMResult != nil {
                    mappingSidebar
                        .frame(minWidth: 220, maxWidth: 280)
                } else {
                    holeSidebar
                        .frame(minWidth: 180, maxWidth: 220)
                }

                VStack(spacing: 0) {
                    mapArea
                    statusBar
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.arrow.set()
                    }
                }

                inspectorPanel
                    .frame(minWidth: 240, maxWidth: 300)
            }
        }
        .focusable()
        .focused($isMapFocused)
        .onKeyPress(characters: CharacterSet(charactersIn: "spc")) { press in
            guard !isMappingMode else { return .ignored }
            if let mode = ToolMode.allCases.first(where: { $0.shortcutKey == press.characters.first }) {
                switchTool(to: mode)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "v")) { _ in
            mapStyleMode = mapStyleMode.next
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "e")) { _ in
            beginEditingSelectedFeature() ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            if !drawingVertices.isEmpty {
                drawingVertices = []
                selectedDrawingVertexIndex = nil
                statusMessage = "Drawing cancelled"
                clearStatusAfterDelay()
            } else if isEditingCenterline {
                isEditingCenterline = false
                selectedCenterlineVertexIndex = nil
            } else if isCenterlineSelected {
                isCenterlineSelected = false
            } else if isEditingFeature {
                isEditingFeature = false
                selectedVertexIndex = nil
            } else {
                deselectAll()
            }
            return .handled
        }
        .onKeyPress(.delete) {
            handleDeleteKey()
            return .handled
        }
        .onKeyPress(KeyEquivalent("\u{7F}")) {
            handleDeleteKey()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            selectAdjacentPolygonVertex(offset: -1)
        }
        .onKeyPress(.rightArrow) {
            selectAdjacentPolygonVertex(offset: 1)
        }
        .onKeyPress(.return) {
            if !drawingVertices.isEmpty {
                finishDrawing()
            } else if isCenterlineSelected && !isEditingCenterline {
                isEditingCenterline = true
            } else if selectedFeatureID != nil && !isEditingFeature {
                beginEditingSelectedFeature()
            }
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.key == KeyEquivalent("z"), press.modifiers.contains(.command) else {
                return .ignored
            }
            if !drawingVertices.isEmpty {
                drawingVertices.removeLast()
                selectedDrawingVertexIndex = nil
                if drawingVertices.isEmpty {
                    statusMessage = "Drawing cancelled"
                    clearStatusAfterDelay()
                }
                return .handled
            }
            return restoreDeletedFeature() ? .handled : .ignored
        }
        .navigationTitle("\(course.name) — \(course.location.cityStateDisplay)")
        .onAppear {
            centerMapOnCourse()
            isMapFocused = true
        }
    }

    // MARK: - Current Hole Helpers

    private var currentHole: Hole? {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count else { return nil }
        return course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex]
    }

    private var allAssignedFeatureIDs: Set<Int> {
        Set(course.subCourses.flatMap(\.holes).flatMap(\.features))
    }

    private var currentHoleFeatureIDs: Set<Int> {
        Set(currentHole?.features ?? [])
    }

    private var currentHoleFeatures: [Feature] {
        guard let hole = currentHole else { return [] }
        return course.features(for: hole)
    }

    private var unassociatedFeatures: [Feature] {
        let assigned = allAssignedFeatureIDs
        return course.features.filter { !assigned.contains($0.id) }
    }

    private var otherHoleFeatures: [Feature] {
        let otherIDs = allAssignedFeatureIDs.subtracting(currentHoleFeatureIDs)
        return course.features.filter { otherIDs.contains($0.id) }
    }

    // MARK: - Hole Sidebar

    // MARK: - Mapping Sidebar (shown during OSM import)

    private var mappingSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Map OSM Holes to Sub-Courses")
                .font(.headline)
                .padding(8)

            Text("Select a group to see its centerlines on the map, then assign it to a sub-course.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(centerlineGroups.enumerated()), id: \.offset) { idx, group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(groupColor(for: idx))
                                    .frame(width: 10, height: 10)
                                Text(group.label)
                                    .font(.body.bold())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedMappingGroup = (selectedMappingGroup == idx) ? nil : idx
                            }

                            Picker("Sub-Course", selection: Binding(
                                get: { centerlineGroups[idx].assignedSubCourseIndex },
                                set: { centerlineGroups[idx].assignedSubCourseIndex = $0 }
                            )) {
                                Text("Select...").tag(nil as Int?)
                                ForEach(Array(course.subCourses.enumerated()), id: \.offset) { subIdx, sc in
                                    Text(sc.name).tag(subIdx as Int?)
                                }
                            }
                            .labelsHidden()
                        }
                        .padding(8)
                        .background(selectedMappingGroup == idx ? groupColor(for: idx).opacity(0.15) : Color.clear)
                        .cornerRadius(6)
                    }
                }
                .padding(8)
            }

            Divider()

            // Inspector for selected centerline — allows moving it to a different group
            if let gIdx = selectedMappingGroup,
               let clIdx = selectedMappingCenterline,
               gIdx < centerlineGroups.count,
               clIdx < centerlineGroups[gIdx].centerlines.count {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    let cl = centerlineGroups[gIdx].centerlines[clIdx]
                    Text("Hole \(cl.holeNumber ?? 0)")
                        .font(.subheadline.bold())
                    Text("Currently in: \(centerlineGroups[gIdx].label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Move to", selection: Binding(
                        get: { gIdx },
                        set: { newGroupIdx in
                            moveCenterline(fromGroup: gIdx, index: clIdx, toGroup: newGroupIdx)
                        }
                    )) {
                        ForEach(centerlineGroups.indices, id: \.self) { idx in
                            HStack {
                                Circle().fill(groupColor(for: idx)).frame(width: 8, height: 8)
                                Text(centerlineGroups[idx].label)
                            }.tag(idx)
                        }
                    }
                }
                .padding(8)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    pendingOSMResult = nil
                    centerlineGroups = []
                    selectedMappingGroup = nil
                    selectedMappingCenterline = nil
                }
                Spacer()
                Button("Import") {
                    Task { await applyMappingAndImport() }
                }
                .disabled(isImportingOSM)
                .disabled(!centerlineGroups.allSatisfy { $0.assignedSubCourseIndex != nil })
            }
            .padding(8)
        }
        .background(Color(.windowBackgroundColor))
    }

    private func moveCenterline(fromGroup: Int, index: Int, toGroup: Int) {
        guard fromGroup != toGroup,
              fromGroup < centerlineGroups.count,
              toGroup < centerlineGroups.count,
              index < centerlineGroups[fromGroup].centerlines.count else { return }

        let cl = centerlineGroups[fromGroup].centerlines[index]
        centerlineGroups[fromGroup].centerlines.remove(at: index)
        centerlineGroups[toGroup].centerlines.append(cl)
        // Update label counts
        centerlineGroups[fromGroup].label = "\(centerlineGroups[fromGroup].centerlines.count) holes (group \(fromGroup + 1))"
        centerlineGroups[toGroup].label = "\(centerlineGroups[toGroup].centerlines.count) holes (group \(toGroup + 1))"
        selectedMappingGroup = toGroup
        selectedMappingCenterline = nil
    }

    private func groupColor(for index: Int) -> Color {
        let colors: [Color] = [.red, .blue, .green, .orange, .purple, .cyan, .yellow, .pink, .mint]
        return colors[index % colors.count]
    }

    private var holeSidebar: some View {
        VSplitView {
            // Holes pane
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "Holes", collapsed: $holesCollapsed)
                if !holesCollapsed {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(course.subCourses.enumerated()), id: \.element.id) { subIdx, subCourse in
                                Text(subCourse.name)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, subIdx > 0 ? 8 : 4)
                                    .padding(.bottom, 2)

                                ForEach(subCourse.holes.indices, id: \.self) { holeIdx in
                                    let hole = subCourse.holes[holeIdx]
                                    let isSelected = selectedSubCourseIndex == subIdx && selectedHoleIndex == holeIdx
                                    HStack {
                                        Text("Hole \(hole.number)")
                                            .fontWeight(isSelected ? .bold : .regular)
                                        Spacer()
                                        Text("\(hole.features.count) features")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedSubCourseIndex = subIdx
                                        selectedHoleIndex = holeIdx
                                        deselectAll()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 30)

            // Features pane
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "Features - Hole \(currentHole?.number ?? 0)", collapsed: $featuresCollapsed)
                if !featuresCollapsed {
                    let holeFeatures = currentHoleFeatures
                    List(holeFeatures) { feature in
                        HStack {
                            Circle()
                                .fill(colorForFeatureType(feature.type))
                                .frame(width: 10, height: 10)
                            Text(feature.type.rawValue.capitalized)
                                .font(.caption)
                            Text("#\(feature.id)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                disassociateFeature(id: feature.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Disassociate from hole")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedFeatureID = feature.id
                            selectedVertexIndex = nil
                            isEditingFeature = false
                            activeTool = .select
                        }
                    }
                }
            }
            .frame(minHeight: 30)

            // Unassociated pane
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "Unassociated (\(unassociatedFeatures.count))", collapsed: $unassociatedCollapsed)
                if !unassociatedCollapsed {
                    let unassociated = unassociatedFeatures
                    List(unassociated) { feature in
                        HStack {
                            Circle()
                                .fill(colorForFeatureType(feature.type))
                                .frame(width: 10, height: 10)
                            Text(feature.type.rawValue.capitalized)
                                .font(.caption)
                            Text("#\(feature.id)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedFeatureID = feature.id
                            selectedVertexIndex = nil
                            isEditingFeature = false
                            activeTool = .select
                        }
                    }
                }
            }
            .frame(minHeight: 30)
        }
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Tool picker (left)
            HStack(spacing: 2) {
                ForEach(ToolMode.allCases, id: \.self) { mode in
                    Button {
                        switchTool(to: mode)
                        isMapFocused = true
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: mode.systemImage)
                                .font(.system(size: 14))
                            Text(String(mode.shortcutKey))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 36, height: 36)
                        .background(activeTool == mode ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(activeTool == mode ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isMappingMode && mode != .select)
                }
            }

            // Feature type picker (for drawing)
            if activeTool == .drawPolygon {
                Picker("Type", selection: $pendingFeatureType) {
                    ForEach(FeatureType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .frame(width: 120)
            }

            Spacer()

            // Course name + distance (center)
            VStack(spacing: 2) {
                Text(course.name)
                    .font(.caption.bold())
                distanceReadout
            }

            Spacer()

            // Guess tees button
            Button("Guess Tees") {
                guessTeesForCurrentHole()
            }
            .disabled(currentHole == nil || isMappingMode)
            .help("Re-guess which tee box each tee plays from, using the centerline")

            // Import OSM button
            Button {
                Task { await importFromOSM() }
            } label: {
                HStack(spacing: 4) {
                    if isImportingOSM {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    Text("Import OSM")
                }
            }
            .disabled(isImportingOSM || !course.features.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Distance Readout

    private var distanceReadout: some View {
        Group {
            let holeFeatures = currentHoleFeatures
            let teeFeature = holeFeatures.first { $0.type == .tee }
            let greenFeature = holeFeatures.first { $0.type == .green }

            if let tee = teeFeature, let green = greenFeature {
                let meters = tee.center.clLocation.distance(from: green.center.clLocation)
                let yards = Int(meters * 1.09361)
                let scorecardYardage: Int = {
                    guard let hole = currentHole else { return 0 }
                    return hole.yardages.values.first ?? 0
                }()

                HStack(spacing: 4) {
                    Text("Measured: \(yards) yds")
                        .font(.caption)
                    if scorecardYardage > 0 {
                        Text("| Card: \(scorecardYardage) yds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Place tee + green polygons for distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Map Area

    private var mapArea: some View {
        MapReader { proxy in
            Map(position: $mapPosition, interactionModes: isDraggingVertex ? [.zoom, .rotate, .pitch] : .all) {
                // Render centerline groups during mapping mode
                if isMappingMode {
                    ForEach(Array(centerlineGroups.enumerated()), id: \.offset) { groupIdx, group in
                        let isGroupSelected = selectedMappingGroup == groupIdx
                        let color = groupColor(for: groupIdx)
                        ForEach(group.centerlines.indices, id: \.self) { clIdx in
                            let cl = group.centerlines[clIdx]
                            let isCLSelected = isGroupSelected && selectedMappingCenterline == clIdx
                            MapPolyline(coordinates: cl.coordinates.map(\.clCoordinate))
                                .stroke(
                                    isCLSelected ? .white : color,
                                    lineWidth: isCLSelected ? 5 : (isGroupSelected ? 3 : 1.5)
                                )
                        }
                    }
                }

                // Render feature polygons for current hole
                ForEach(currentHoleFeatures) { feature in
                    let isSelected = selectedFeatureID == feature.id
                    MapPolygon(coordinates: feature.polygon.map(\.clCoordinate))
                        .foregroundStyle(colorForFeatureType(feature.type).opacity(isSelected ? 0.5 : 0.3))
                        .stroke(colorForFeatureType(feature.type), lineWidth: isSelected ? 3 : 1.5)
                }

                // Render unassociated features (other-hole features are not rendered
                // to keep the map responsive with large courses)
                ForEach(unassociatedFeatures) { feature in
                    let isSelected = selectedFeatureID == feature.id
                    MapPolygon(coordinates: feature.polygon.map(\.clCoordinate))
                        .foregroundStyle(colorForFeatureType(feature.type).opacity(isSelected ? 0.5 : 0.15))
                        .stroke(colorForFeatureType(feature.type).opacity(0.5), lineWidth: isSelected ? 3 : 1)
                }

                // Render selected feature if it's not already visible (other-hole feature)
                if let featureID = selectedFeatureID,
                   !currentHoleFeatureIDs.contains(featureID),
                   !unassociatedFeatures.contains(where: { $0.id == featureID }),
                   let feature = course.findFeature(id: featureID) {
                    MapPolygon(coordinates: feature.polygon.map(\.clCoordinate))
                        .foregroundStyle(colorForFeatureType(feature.type).opacity(0.5))
                        .stroke(colorForFeatureType(feature.type), lineWidth: 3)
                }

                // Render centerline for current hole
                if let hole = currentHole, hole.centerline.count >= 2 {
                    MapPolyline(coordinates: hole.centerline.map(\.clCoordinate))
                        .stroke(isCenterlineSelected ? .yellow : .white, lineWidth: isCenterlineSelected ? 3 : 2)
                }

                // Render vertex handles for selected centerline (in edit mode)
                if isEditingCenterline, let hole = currentHole, hole.centerline.count >= 2 {
                    ForEach(Array(hole.centerline.enumerated()), id: \.offset) { index, coord in
                        Annotation("", coordinate: coord.clCoordinate) {
                            Circle()
                                .fill(selectedCenterlineVertexIndex == index ? Color.white : Color.yellow)
                                .stroke(Color.white, lineWidth: 1.5)
                                .frame(width: 12, height: 12)
                                .offset(selectedCenterlineVertexIndex == index && isDraggingVertex ? dragOffset : .zero)
                                .onTapGesture {
                                    selectedCenterlineVertexIndex = index
                                }
                        }
                    }
                }

                // Render vertex handles for selected feature (only in edit mode)
                if isEditingFeature,
                   let featureID = selectedFeatureID,
                   let feature = course.findFeature(id: featureID) {
                    ForEach(Array(feature.polygon.enumerated()), id: \.offset) { index, coord in
                        Annotation("", coordinate: coord.clCoordinate) {
                            Circle()
                                .fill(selectedVertexIndex == index ? Color.white : Color.accentColor)
                                .stroke(Color.white, lineWidth: 1.5)
                                .frame(width: 12, height: 12)
                                .offset(selectedVertexIndex == index && isDraggingVertex ? dragOffset : .zero)
                                .onTapGesture {
                                    selectedVertexIndex = index
                                }
                        }
                    }
                }

                // Render in-progress drawing
                if drawingVertices.count >= 2 {
                    if activeTool == .drawPolygon {
                        MapPolygon(coordinates: drawingVertices.map(\.clCoordinate))
                            .foregroundStyle(colorForFeatureType(pendingFeatureType).opacity(0.2))
                            .stroke(colorForFeatureType(pendingFeatureType), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    } else {
                        MapPolyline(coordinates: drawingVertices.map(\.clCoordinate))
                            .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                }

                // Drawing vertex dots — first vertex is larger to indicate click-to-close
                ForEach(Array(drawingVertices.enumerated()), id: \.offset) { index, coord in
                    Annotation("", coordinate: coord.clCoordinate) {
                        if index == 0 && drawingVertices.count >= 3 && activeTool == .drawPolygon {
                            Circle()
                                .fill(Color.white)
                                .stroke(colorForFeatureType(pendingFeatureType), lineWidth: 2)
                                .frame(width: 14, height: 14)
                        } else if selectedDrawingVertexIndex == index {
                            Circle()
                                .fill(Color.white)
                                .stroke(Color.yellow, lineWidth: 2)
                                .frame(width: 12, height: 12)
                        } else {
                            Circle()
                                .fill(Color.yellow)
                                .stroke(Color.white, lineWidth: 1)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapZoomStepper()
                MapPitchToggle()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                visibleRegion = context.region
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if let coordinate = proxy.convert(location, from: .local) {
                        hoveredMapCoordinate = Coordinate(coordinate)
                    } else {
                        hoveredMapCoordinate = nil
                    }
                case .ended:
                    hoveredMapCoordinate = nil
                }
            }
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { mapViewSize = geometry.size }
                        .onChange(of: geometry.size) { _, newSize in mapViewSize = newSize }
                }
            }
            .overlay {
                // Drag handle for selected feature vertex (only in edit mode)
                if activeTool == .select,
                   isEditingFeature,
                   let featureID = selectedFeatureID,
                   let vertexIdx = selectedVertexIndex,
                   let feature = course.findFeature(id: featureID),
                   vertexIdx < feature.polygon.count,
                   let screenPoint = proxy.convert(feature.polygon[vertexIdx].clCoordinate, to: .local) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(screenPoint)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    isDraggingVertex = true
                                    dragOffset = value.translation
                                }
                                .onEnded { value in
                                    updateVertexAfterDrag(featureID: featureID, vertexIndex: vertexIdx, translation: value.translation)
                                    dragOffset = .zero
                                    isDraggingVertex = false
                                }
                        )
                }
            }
            .overlay {
                // Drag handle for selected centerline vertex
                if activeTool == .select,
                   isEditingCenterline,
                   let vertexIdx = selectedCenterlineVertexIndex,
                   let hole = currentHole,
                   vertexIdx < hole.centerline.count,
                   let screenPoint = proxy.convert(hole.centerline[vertexIdx].clCoordinate, to: .local) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(screenPoint)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    isDraggingVertex = true
                                    dragOffset = value.translation
                                }
                                .onEnded { value in
                                    applyCenterlineVertexDrag(vertexIndex: vertexIdx, translation: value.translation)
                                    dragOffset = .zero
                                    isDraggingVertex = false
                                }
                        )
                }
            }
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: SpatialTapGesture())
                    .onEnded { value in
                        switch value {
                        case .first(let tap):
                            guard activeTool == .select,
                                  isEditingFeature,
                                  let featureID = selectedFeatureID,
                                  let feature = course.findFeature(id: featureID),
                                  let edge = PolygonEditorOperations.nearestEdge(
                                    to: tap.location,
                                    polygon: feature.polygon,
                                    convert: { proxy.convert($0, to: .local) }
                                  ),
                                  let coordinate = proxy.convert(edge.point, from: .local) else { return }
                            addVertex(
                                Coordinate(coordinate),
                                to: featureID,
                                at: edge.insertionIndex
                            )
                        case .second(let tap):
                            guard let coord = proxy.convert(tap.location, from: .local) else { return }
                            handleMapTap(at: Coordinate(coord))
                        }
                    }
            )
            .overlay(alignment: .topTrailing) {
                mapStylePicker
                    .padding(8)
            }
        }
    }

    private var mapStylePicker: some View {
        Menu {
            ForEach(MapStyleMode.allCases, id: \.self) { mode in
                Button(mode.rawValue) { mapStyleMode = mode }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "map")
                Text("(\(mapStyleMode.rawValue.prefix(3).lowercased()))")
                    .font(.system(size: 9, design: .monospaced))
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Inspector Panel

    private var inspectorPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector")
                .font(.headline)
                .padding()

            Divider()

            if let featureID = selectedFeatureID,
               let featureIndex = course.features.firstIndex(where: { $0.id == featureID }),
               selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count {
                VStack(alignment: .leading, spacing: 0) {
                    FeatureEditorView(
                        feature: $course.features[featureIndex],
                        hole: $course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex],
                        teeNames: course.tees.map(\.name),
                        onDelete: {
                            featureToDelete = featureID
                        }
                    )

                    Divider()

                    // Associate/Disassociate controls
                    VStack(alignment: .leading, spacing: 8) {
                        let isAssociated = currentHole?.features.contains(featureID) ?? false

                        if isAssociated {
                            Button("Disassociate from Hole \(currentHole?.number ?? 0)") {
                                disassociateFeature(id: featureID)
                            }
                        } else {
                            Button("Associate with Hole \(currentHole?.number ?? 0)") {
                                associateFeature(id: featureID)
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: activeTool == .select ? "cursorarrow.click" : "pencil.and.outline")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text(inspectorHelpText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.windowBackgroundColor))
        .confirmationDialog(
            "Delete Feature #\(featureToDelete ?? 0)?",
            isPresented: Binding(
                get: { featureToDelete != nil },
                set: { if !$0 { featureToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = featureToDelete {
                    deleteFeature(id: id)
                    featureToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                featureToDelete = nil
            }
        } message: {
            Text("This will remove this feature from the course and all holes. You can undo this action.")
        }
    }

    private var inspectorHelpText: String {
        switch activeTool {
        case .select:
            "Click a polygon to select it.\nDrag vertices to reshape."
        case .drawPolygon:
            "Click to place vertices.\nPress Enter to finish polygon."
        case .drawCenterline:
            "Click to place waypoints.\nPress Enter to finish centerline."
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Active tool indicator
            HStack(spacing: 4) {
                Image(systemName: activeTool.systemImage)
                    .font(.caption)
                Text(activeTool.rawValue)
                    .font(.caption.bold())
                Text("(\(String(activeTool.shortcutKey)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 12)

            // Tool hint
            Text(toolHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Status message
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // OSM import status
            if !osmImportStatus.isEmpty {
                Text(osmImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Hole + feature count
            let subName = course.subCourses.indices.contains(selectedSubCourseIndex) ? course.subCourses[selectedSubCourseIndex].name : ""
            Text("\(subName) Hole \(currentHole?.number ?? 0)")
                .font(.caption)
            Text("\(currentHoleFeatures.count) features")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    private var toolHint: String {
        switch activeTool {
        case .select:
            if isEditingCenterline && selectedCenterlineVertexIndex != nil {
                "Drag vertex to move | Del to remove vertex | Esc to stop editing"
            } else if isEditingCenterline {
                "Click vertex to select | Esc to stop editing"
            } else if isCenterlineSelected {
                "Click again or Enter to edit | Esc to deselect | Del to remove centerline"
            } else if isEditingFeature && selectedVertexIndex != nil {
                "←/→ select point | Drag to move | Del to remove | Esc to stop editing"
            } else if isEditingFeature {
                "Click point or use ←/→ to select | Esc to stop editing"
            } else if selectedFeatureID != nil {
                "Click again or Enter to edit | Esc to deselect | Del to remove feature"
            } else {
                "Click polygon or centerline to select"
            }
        case .drawPolygon:
            if drawingVertices.isEmpty {
                "Click to place first vertex"
            } else {
                if selectedDrawingVertexIndex != nil {
                    "\(drawingVertices.count) vertices | Del to remove point | ⌘Z to undo | Esc to cancel"
                } else if drawingVertices.count >= 3 {
                    "\(drawingVertices.count) vertices | Click first point to close | ⌘Z to undo | Esc to cancel"
                } else {
                    "\(drawingVertices.count) vertices | Click to add (\(3 - drawingVertices.count) more needed) | ⌘Z to undo | Esc to cancel"
                }
            }
        case .drawCenterline:
            if drawingVertices.isEmpty {
                "Click to place first waypoint"
            } else {
                "\(drawingVertices.count) waypoints | Click to add | Enter to finish | Esc to cancel"
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, collapsed: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(title)
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                collapsed.wrappedValue.toggle()
            }
        }
    }

    // MARK: - Feature Colors

    /// Hit-test priority for feature types. Lower values are checked first.
    private func featureHitPriority(_ type: FeatureType) -> Int {
        switch type {
        case .tee: 0
        case .green: 1
        case .bunker: 2
        case .water: 3
        case .fairway: 4
        case .rough: 5
        }
    }

    private func colorForFeatureType(_ type: FeatureType) -> Color {
        switch type {
        case .fairway: .green
        case .green: .mint
        case .tee: .blue
        case .bunker: .yellow
        case .water: .cyan
        case .rough: .brown
        }
    }

    // MARK: - Tool Switching

    private func switchTool(to mode: ToolMode) {
        if !drawingVertices.isEmpty {
            drawingVertices = []
            selectedDrawingVertexIndex = nil
        }
        activeTool = mode
        if mode != .select {
            deselectAll()
        }
    }

    // MARK: - Map Tap Handling

    private func handleMapTap(at coordinate: Coordinate) {
        switch activeTool {
        case .select:
            selectFeatureAt(coordinate)
        case .drawPolygon:
            // If we have 3+ vertices and the click is near the first vertex, close the polygon
            if drawingVertices.count >= 3, isClose(coordinate, to: drawingVertices[0], pixels: 10) {
                finishDrawing()
                return
            }
            // Check if clicking an existing drawing vertex to select it
            for (index, vertex) in drawingVertices.enumerated() {
                if isClose(coordinate, to: vertex, pixels: 10) {
                    selectedDrawingVertexIndex = index
                    return
                }
            }
            // Otherwise add a new vertex
            selectedDrawingVertexIndex = nil
            drawingVertices.append(coordinate)
        case .drawCenterline:
            drawingVertices.append(coordinate)
        }
    }

    private func selectFeatureAt(_ point: Coordinate) {
        // In mapping mode, find the nearest centerline
        if isMappingMode {
            selectCenterlineAt(point)
            return
        }

        // In centerline edit mode, check if tapping near a centerline vertex
        if isEditingCenterline, let hole = currentHole {
            for (index, vertex) in hole.centerline.enumerated() {
                if isClose(point, to: vertex) {
                    selectedCenterlineVertexIndex = index
                    return
                }
            }
        }

        // In feature edit mode, check if tapping near a vertex of the selected feature
        if isEditingFeature,
           let featureID = selectedFeatureID,
           let feature = course.findFeature(id: featureID) {
            for (index, vertex) in feature.polygon.enumerated() {
                if isClose(point, to: vertex) {
                    selectedVertexIndex = index
                    return
                }
            }
        }

        // Check all features, sorted by type priority so small features (tees, greens)
        // are hit before large ones (fairways, rough). Use bounding-box pre-filter to
        // avoid expensive point-in-polygon tests on distant features.
        let candidates = course.features
            .filter { feature in
                let lats = feature.polygon.map(\.latitude)
                let lons = feature.polygon.map(\.longitude)
                guard let minLat = lats.min(), let maxLat = lats.max(),
                      let minLon = lons.min(), let maxLon = lons.max() else { return false }
                return point.latitude >= minLat && point.latitude <= maxLat
                    && point.longitude >= minLon && point.longitude <= maxLon
            }
            .sorted { featureHitPriority($0.type) < featureHitPriority($1.type) }

        // Small features (tees, greens, bunkers, water) are hit before the centerline,
        // which usually runs through them. The centerline is hit before fairways and
        // rough, which usually lie under it.
        let centerlinePriority = featureHitPriority(.fairway)
        if let feature = candidates.first(where: {
            featureHitPriority($0.type) < centerlinePriority && PolygonGeometry.contains(point, in: $0.polygon)
        }) {
            selectOrEditFeature(feature)
            return
        }

        // Check if tapping near the current hole's centerline
        if let hole = currentHole, hole.centerline.count >= 2, let region = visibleRegion {
            let dist = distanceToPolyline(from: point, polyline: hole.centerline)
            let tapThreshold = region.span.latitudeDelta / (mapViewSize.height / 15.0)
            if dist < tapThreshold {
                if isCenterlineSelected && !isEditingCenterline {
                    // Second click enters edit mode
                    isEditingCenterline = true
                    selectedCenterlineVertexIndex = nil
                } else if !isCenterlineSelected {
                    // First click selects
                    deselectAll()
                    isCenterlineSelected = true
                }
                return
            }
        }

        if let feature = candidates.first(where: {
            featureHitPriority($0.type) >= centerlinePriority && PolygonGeometry.contains(point, in: $0.polygon)
        }) {
            selectOrEditFeature(feature)
            return
        }

        // Nothing hit, deselect
        deselectAll()
    }

    private func selectOrEditFeature(_ feature: Feature) {
        if selectedFeatureID == feature.id && !isEditingFeature {
            // Second click enters edit mode
            beginEditingSelectedFeature()
        } else {
            deselectAll()
            selectedFeatureID = feature.id
        }
    }

    @discardableResult
    private func beginEditingSelectedFeature() -> Bool {
        guard let featureID = selectedFeatureID,
              let feature = course.findFeature(id: featureID),
              !feature.polygon.isEmpty else { return false }

        isEditingFeature = true
        if let hoveredMapCoordinate {
            selectedVertexIndex = PolygonEditorOperations.nearestVertexIndex(to: hoveredMapCoordinate, in: feature.polygon)
        } else {
            selectedVertexIndex = nil
        }
        return true
    }

    private func deselectAll() {
        selectedFeatureID = nil
        selectedVertexIndex = nil
        isEditingFeature = false
        isCenterlineSelected = false
        isEditingCenterline = false
        selectedCenterlineVertexIndex = nil
    }

    private func selectAdjacentPolygonVertex(offset: Int) -> KeyPress.Result {
        guard isEditingFeature,
              let featureID = selectedFeatureID,
              let feature = course.findFeature(id: featureID),
              !feature.polygon.isEmpty else { return .ignored }

        selectedVertexIndex = PolygonEditorOperations.adjacentVertexIndex(
            current: selectedVertexIndex,
            count: feature.polygon.count,
            offset: offset
        )
        return .handled
    }

    private func addVertex(_ coordinate: Coordinate, to featureID: Int, at insertionIndex: Int) {
        guard let featureIndex = course.features.firstIndex(where: { $0.id == featureID }),
              insertionIndex <= course.features[featureIndex].polygon.count else { return }

        course.features[featureIndex].polygon.insert(coordinate, at: insertionIndex)
        selectedVertexIndex = insertionIndex
        statusMessage = "Updating point elevation..."
        Task { await updateElevation(for: coordinate, featureID: featureID) }
    }

    private func updateElevation(for coordinate: Coordinate, featureID: Int) async {
        do {
            let elevations = try await Task.detached(priority: .utility) {
                try await USGSElevationClient().elevations(for: [coordinate])
            }.value
            guard let elevation = elevations.first ?? nil else {
                throw USGSElevationClient.ElevationError.noData(missing: 1, total: 1)
            }
            guard PolygonEditorOperations.applyElevation(elevation, to: coordinate, featureID: featureID, in: &course) else { return }
            statusMessage = "Updated point elevation"
        } catch {
            logger.error("Background elevation update failed for polygon point: \(error, privacy: .public)")
            statusMessage = "Point elevation update failed: \(error.localizedDescription)"
        }
        clearStatusAfterDelay()
    }

    private func distanceToPolyline(from point: Coordinate, polyline: [Coordinate]) -> Double {
        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<(polyline.count - 1) {
            let dist = sqrt(PolygonGeometry.squaredDistanceToSegment(point, segStart: polyline[i], segEnd: polyline[i + 1]))
            if dist < minDist { minDist = dist }
        }
        return minDist
    }

    private func isClose(_ a: Coordinate, to b: Coordinate, pixels: CGFloat = 20) -> Bool {
        guard let region = visibleRegion else { return false }
        let threshold = region.span.latitudeDelta / (mapViewSize.height / pixels)
        return abs(a.latitude - b.latitude) < threshold && abs(a.longitude - b.longitude) < threshold
    }

    private func selectCenterlineAt(_ point: Coordinate) {
        var bestGroupIdx: Int?
        var bestClIdx: Int?
        var bestDist = Double.greatestFiniteMagnitude

        for (gIdx, group) in centerlineGroups.enumerated() {
            for (clIdx, cl) in group.centerlines.enumerated() {
                let dist = OSMImporter.distanceToPolyline(from: point, polyline: cl.coordinates)
                if dist < bestDist {
                    bestDist = dist
                    bestGroupIdx = gIdx
                    bestClIdx = clIdx
                }
            }
        }

        // Only select if within a reasonable tap distance (~50 meters)
        if bestDist < 50, let gIdx = bestGroupIdx, let clIdx = bestClIdx {
            selectedMappingGroup = gIdx
            selectedMappingCenterline = clIdx
        } else {
            selectedMappingCenterline = nil
        }
    }

    // MARK: - Finish Drawing

    private func finishDrawing() {
        switch activeTool {
        case .drawPolygon:
            guard drawingVertices.count >= 3 else {
                statusMessage = "Need at least 3 vertices for a polygon"
                clearStatusAfterDelay()
                return
            }
            guard !isCompletingPolygon else { return }
            Task { await completePolygon() }

        case .drawCenterline:
            guard drawingVertices.count >= 2 else {
                statusMessage = "Need at least 2 waypoints for a centerline"
                clearStatusAfterDelay()
                return
            }
            let vertices = drawingVertices
            let subCourseIndex = selectedSubCourseIndex
            let holeIndex = selectedHoleIndex
            drawingVertices = []
            guard subCourseIndex < course.subCourses.count,
                  holeIndex < course.subCourses[subCourseIndex].holes.count else { return }
            course.subCourses[subCourseIndex].holes[holeIndex].centerline = vertices
            statusMessage = "Updating centerline elevations..."
            Task { await updateCenterlineElevations(for: vertices, subCourseIndex: subCourseIndex, holeIndex: holeIndex) }

        case .select:
            break
        }
    }

    private func completePolygon() async {
        isCompletingPolygon = true
        let vertices = drawingVertices
        let featureType = pendingFeatureType
        statusMessage = "Updating polygon elevations..."

        do {
            let elevations = try await USGSElevationClient().elevations(for: vertices)
            let resolved = elevations.compactMap { $0 }
            guard elevations.count == vertices.count, resolved.count == vertices.count else {
                throw USGSElevationClient.ElevationError.noData(
                    missing: vertices.count - resolved.count,
                    total: vertices.count
                )
            }

            let elevatedVertices = zip(vertices, resolved).map { coordinate, elevation in
                var elevated = coordinate
                elevated.elevation = elevation
                return elevated
            }
            let newFeature = Feature(
                id: course.nextFeatureID,
                type: featureType,
                polygon: elevatedVertices
            )
            course.features.append(newFeature)

            if selectedSubCourseIndex < course.subCourses.count,
               selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count {
                course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].features.append(newFeature.id)
            }

            selectedFeatureID = newFeature.id
            selectedVertexIndex = nil
            isEditingFeature = false
            drawingVertices = []
            selectedDrawingVertexIndex = nil
            activeTool = .select
            statusMessage = "Created \(featureType.rawValue) feature #\(newFeature.id)"
        } catch {
            logger.error("Elevation update failed for manual polygon: \(error, privacy: .public)")
            statusMessage = "Polygon elevation update failed: \(error.localizedDescription)"
        }

        isCompletingPolygon = false
        clearStatusAfterDelay()
    }

    // MARK: - Vertex Dragging

    private func updateVertexAfterDrag(featureID: Int, vertexIndex: Int, translation: CGSize) {
        guard let region = visibleRegion, mapViewSize.width > 0, mapViewSize.height > 0,
              let featureIndex = course.features.firstIndex(where: { $0.id == featureID }),
              vertexIndex < course.features[featureIndex].polygon.count else { return }
        let degreesPerPixelLat = region.span.latitudeDelta / mapViewSize.height
        let degreesPerPixelLng = region.span.longitudeDelta / mapViewSize.width
        var movedCoordinate = course.features[featureIndex].polygon[vertexIndex]
        movedCoordinate.latitude -= translation.height * degreesPerPixelLat
        movedCoordinate.longitude += translation.width * degreesPerPixelLng
        movedCoordinate.elevation = nil
        course.features[featureIndex].polygon[vertexIndex] = movedCoordinate
        statusMessage = "Updating point elevation..."
        Task { await updateElevation(for: movedCoordinate, featureID: featureID) }
    }

    private func applyCenterlineVertexDrag(vertexIndex: Int, translation: CGSize) {
        guard let region = visibleRegion, mapViewSize.width > 0, mapViewSize.height > 0,
              selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count,
              vertexIndex < course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].centerline.count else { return }
        let degreesPerPixelLat = region.span.latitudeDelta / mapViewSize.height
        let degreesPerPixelLng = region.span.longitudeDelta / mapViewSize.width
        let subCourseIndex = selectedSubCourseIndex
        let holeIndex = selectedHoleIndex
        var movedCoordinate = course.subCourses[subCourseIndex].holes[holeIndex].centerline[vertexIndex]
        movedCoordinate.latitude -= translation.height * degreesPerPixelLat
        movedCoordinate.longitude += translation.width * degreesPerPixelLng
        // The old elevation belongs to the old position.
        movedCoordinate.elevation = nil
        course.subCourses[subCourseIndex].holes[holeIndex].centerline[vertexIndex] = movedCoordinate
        statusMessage = "Updating point elevation..."
        Task { await updateCenterlineElevations(for: [movedCoordinate], subCourseIndex: subCourseIndex, holeIndex: holeIndex) }
    }

    private func updateCenterlineElevations(for coordinates: [Coordinate], subCourseIndex: Int, holeIndex: Int) async {
        do {
            let elevations = try await Task.detached(priority: .utility) {
                try await USGSElevationClient().elevations(for: coordinates)
            }.value
            let resolved = elevations.compactMap { $0 }
            guard elevations.count == coordinates.count, resolved.count == coordinates.count else {
                throw USGSElevationClient.ElevationError.noData(
                    missing: coordinates.count - resolved.count,
                    total: coordinates.count
                )
            }
            for (coordinate, elevation) in zip(coordinates, resolved) {
                PolygonEditorOperations.applyCenterlineElevation(
                    elevation,
                    to: coordinate,
                    subCourseIndex: subCourseIndex,
                    holeIndex: holeIndex,
                    in: &course
                )
            }
            statusMessage = "Updated centerline elevations"
        } catch {
            logger.error("Background elevation update failed for centerline: \(error, privacy: .public)")
            statusMessage = "Centerline elevation update failed: \(error.localizedDescription)"
        }
        clearStatusAfterDelay()
    }

    // MARK: - Delete Handling

    private func handleDeleteKey() {
        if activeTool == .drawPolygon, let idx = selectedDrawingVertexIndex {
            // Delete selected vertex during polygon drawing
            drawingVertices.remove(at: idx)
            if drawingVertices.isEmpty {
                selectedDrawingVertexIndex = nil
            } else if idx >= drawingVertices.count {
                selectedDrawingVertexIndex = drawingVertices.count - 1
            }
        } else if activeTool == .drawPolygon, !drawingVertices.isEmpty {
            // No vertex selected during drawing — remove the last vertex (same as undo)
            drawingVertices.removeLast()
            selectedDrawingVertexIndex = nil
        } else if isEditingCenterline, let idx = selectedCenterlineVertexIndex {
            // Delete selected centerline vertex
            deleteCenterlineVertex(at: idx)
        } else if isEditingFeature, selectedVertexIndex != nil {
            deleteSelectedVertex()
        } else if isCenterlineSelected {
            // Delete entire centerline
            deleteCenterline()
        } else {
            deleteSelectedFeature()
        }
    }

    // MARK: - Vertex Deletion

    private func deleteSelectedVertex() {
        guard let featureID = selectedFeatureID,
              let vertexIdx = selectedVertexIndex,
              let featureIndex = course.features.firstIndex(where: { $0.id == featureID }),
              vertexIdx < course.features[featureIndex].polygon.count else { return }

        // A polygon needs at least 3 vertices
        if course.features[featureIndex].polygon.count <= 3 {
            statusMessage = "Cannot delete vertex — polygon needs at least 3 points"
            clearStatusAfterDelay()
            return
        }

        course.features[featureIndex].polygon.remove(at: vertexIdx)
        // Adjust selection: select previous vertex, or wrap to last
        if vertexIdx >= course.features[featureIndex].polygon.count {
            selectedVertexIndex = course.features[featureIndex].polygon.count - 1
        }
    }

    // MARK: - Centerline Management

    private func deleteCenterlineVertex(at index: Int) {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count else { return }
        let count = course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].centerline.count
        guard index < count else { return }
        if count <= 2 {
            statusMessage = "Cannot delete vertex — centerline needs at least 2 points"
            clearStatusAfterDelay()
            return
        }
        course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].centerline.remove(at: index)
        let newCount = course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].centerline.count
        if index >= newCount {
            selectedCenterlineVertexIndex = newCount - 1
        }
    }

    private func deleteCenterline() {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count else { return }
        course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].centerline = []
        deselectAll()
        statusMessage = "Centerline deleted"
        clearStatusAfterDelay()
    }

    // MARK: - Feature Management

    private func disassociateFeature(id: Int) {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count
        else { return }
        course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].features.removeAll { $0 == id }
    }

    private func guessTeesForCurrentHole() {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count
        else { return }
        let hole = course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex]
        if hole.yardages.isEmpty {
            statusMessage = "Hole \(hole.number) has no yardages"
        } else if hole.centerline.count < 2 {
            statusMessage = "Hole \(hole.number) needs a centerline"
        } else {
            let tees = TeeGuesser.guessTees(for: hole, features: course.features)
            if tees.isEmpty {
                statusMessage = "Hole \(hole.number) has no tee boxes"
            } else {
                course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].tees = tees
                statusMessage = "Guessed \(tees.count) tees for hole \(hole.number)"
            }
        }
        clearStatusAfterDelay()
    }

    private func associateFeature(id: Int) {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count
        else { return }
        if !course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].features.contains(id) {
            course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].features.append(id)
        }
    }

    private func deleteSelectedFeature() {
        guard let featureID = selectedFeatureID else { return }
        featureToDelete = featureID
    }

    private func deleteFeature(id: Int) {
        guard let record = PolygonEditorOperations.deleteFeature(id: id, from: &course) else { return }
        deletedFeatureRecords.append(record)
        selectedFeatureID = nil
        selectedVertexIndex = nil
        isEditingFeature = false
    }

    @discardableResult
    private func restoreDeletedFeature() -> Bool {
        guard let record = deletedFeatureRecords.popLast(),
              PolygonEditorOperations.restoreFeature(record, to: &course) else { return false }
        selectedFeatureID = record.feature.id
        statusMessage = "Restored feature #\(record.feature.id)"
        clearStatusAfterDelay()
        return true
    }

    // MARK: - OSM Import

    private func importFromOSM() async {
        isImportingOSM = true
        osmImportStatus = "Querying OpenStreetMap..."
        let client = OverpassAPIClient()
        let clubhouseCoord = course.location.coordinate
        logger.info("Starting OSM import for course '\(course.name, privacy: .public)' at \(clubhouseCoord.latitude, privacy: .public), \(clubhouseCoord.longitude, privacy: .public)")
        let searchBBox = OverpassAPIClient.boundingBox(around: clubhouseCoord, radiusMeters: 1000)
        do {
            let result = try await client.fetchFeatures(bbox: searchBBox)
            logger.info("Initial query: \(result.features.count, privacy: .public) features, \(result.centerlines.count, privacy: .public) centerlines, boundary: \(result.courseBoundary != nil, privacy: .public)")

            var finalResult = result
            if let boundary = result.courseBoundary, boundary.count >= 3 {
                let lats = boundary.map(\.latitude)
                let lons = boundary.map(\.longitude)
                let bbox = OverpassAPIClient.BoundingBox(
                    south: lats.min()!, west: lons.min()!,
                    north: lats.max()!, east: lons.max()!
                ).padded(by: 0.25)
                osmImportStatus = "Fetching features within course boundary..."
                finalResult = try await client.fetchFeatures(bbox: bbox)
                logger.info("Full query: \(finalResult.features.count, privacy: .public) features")
            }

            // Group centerlines to match sub-course count and present mapping dialog
            centerlineGroups = buildCenterlineGroups(
                from: finalResult.centerlines,
                subCourseSizes: course.subCourses.map(\.holes.count)
            )
            pendingOSMResult = finalResult
            osmImportStatus = ""
        } catch {
            logger.error("OSM import failed: \(error, privacy: .public)")
            osmImportStatus = "Import failed: \(error.localizedDescription)"
        }
        isImportingOSM = false
        clearOSMStatusAfterDelay()
    }

    /// Group centerlines into chains by traversing them in playing order.
    ///
    /// Starting from each unvisited hole with ref=1, follow the chain: find the
    /// centerline with ref=2 whose start is nearest to the current hole's end,
    /// then ref=3, etc. Each chain is limited to the expected sub-course size
    /// to prevent jumping across nines (e.g., hole 9 → hole 10 on a different nine).
    /// Leftover centerlines (e.g., holes 10-18) form additional chains.
    private func buildCenterlineGroups(
        from centerlines: [OverpassAPIClient.ParsedCenterline],
        subCourseSizes: [Int]
    ) -> [CenterlineGroup] {
        let valid = centerlines.filter { $0.holeNumber != nil && $0.coordinates.count >= 2 }
        guard !valid.isEmpty, !subCourseSizes.isEmpty else { return [] }

        let maxChainLength = subCourseSizes.max() ?? 9
        var used: Set<Int> = [] // indices into `valid`
        var groups: [CenterlineGroup] = []

        // Find all hole-1 centerlines as chain starting points
        let starts = valid.enumerated().filter { $0.element.holeNumber == 1 }

        for (startIdx, startCL) in starts {
            if used.contains(startIdx) { continue }

            var chain: [OverpassAPIClient.ParsedCenterline] = [startCL]
            used.insert(startIdx)
            var currentEnd = startCL.coordinates.last!

            var nextRef = 2
            while chain.count < maxChainLength {
                var bestIdx: Int?
                var bestDist = Double.greatestFiniteMagnitude
                for (i, cl) in valid.enumerated() {
                    guard cl.holeNumber == nextRef, !used.contains(i) else { continue }
                    let dist = cl.coordinates.first!.clLocation.distance(from: currentEnd.clLocation)
                    if dist < bestDist {
                        bestDist = dist
                        bestIdx = i
                    }
                }

                guard let idx = bestIdx else { break }

                chain.append(valid[idx])
                used.insert(idx)
                currentEnd = valid[idx].coordinates.last!
                nextRef += 1
            }

            groups.append(CenterlineGroup(
                label: "\(chain.count) holes (group \(groups.count + 1))",
                centerlines: chain,
                assignedSubCourseIndex: nil
            ))
        }

        // Pick up remaining centerlines (e.g., holes 10-18 with no ref=1 start)
        let remaining = valid.enumerated().filter { !used.contains($0.offset) }
        if !remaining.isEmpty {
            // Sort by ref and traverse
            let sortedRemaining = remaining.sorted { ($0.element.holeNumber ?? 0) < ($1.element.holeNumber ?? 0) }
            var remainingUsed: Set<Int> = []

            // Start chains from the lowest unused ref
            for (startIdx, startCL) in sortedRemaining {
                if remainingUsed.contains(startIdx) { continue }

                var chain: [OverpassAPIClient.ParsedCenterline] = [startCL]
                remainingUsed.insert(startIdx)
                var currentEnd = startCL.coordinates.last!
                let startRef = startCL.holeNumber ?? 0

                var nextRef = startRef + 1
                while chain.count < maxChainLength {
                    var bestIdx: Int?
                    var bestDist = Double.greatestFiniteMagnitude
                    for (idx, cl) in sortedRemaining {
                        guard cl.holeNumber == nextRef, !remainingUsed.contains(idx) else { continue }
                        let dist = cl.coordinates.first!.clLocation.distance(from: currentEnd.clLocation)
                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = idx
                        }
                    }

                    guard let idx = bestIdx else { break }
                    let cl = valid[idx]
                    chain.append(cl)
                    remainingUsed.insert(idx)
                    currentEnd = cl.coordinates.last!
                    nextRef += 1
                }

                groups.append(CenterlineGroup(
                    label: "\(chain.count) holes (group \(groups.count + 1))",
                    centerlines: chain,
                    assignedSubCourseIndex: nil
                ))
            }
        }

        return groups
    }

    private func applyMappingAndImport() async {
        guard let result = pendingOSMResult else { return }

        // Build renumbered centerlines based on user's sub-course mapping
        var renumbered: [OverpassAPIClient.ParsedCenterline] = []
        for group in centerlineGroups {
            guard let subIdx = group.assignedSubCourseIndex else { continue }

            // Compute global hole offset for this sub-course
            var globalOffset = 0
            for i in 0..<subIdx {
                globalOffset += course.subCourses[i].holes.count
            }

            for (holeIdx, centerline) in group.centerlines.enumerated() {
                let globalNumber = globalOffset + holeIdx + 1
                renumbered.append(OverpassAPIClient.ParsedCenterline(
                    holeNumber: globalNumber,
                    coordinates: centerline.coordinates
                ))
            }
        }

        let mappedResult = OverpassAPIClient.ParsedResult(
            features: result.features,
            centerlines: renumbered,
            courseBoundary: result.courseBoundary
        )

        let featureCountBefore = course.features.count
        var importedCourse = course
        OSMImporter.applyParsedResult(mappedResult, to: &importedCourse)
        let importedFeatureCount = importedCourse.features.count - featureCountBefore

        isImportingOSM = true
        osmImportStatus = "Updating elevations..."
        do {
            course = try await ElevationUpdater.update(importedCourse) { completed, total in
                Task { @MainActor in
                    osmImportStatus = "Updating elevations (\(completed)/\(total))..."
                }
            }
            logger.info("Imported \(importedFeatureCount, privacy: .public) features and updated elevations")
            osmImportStatus = "Imported \(importedFeatureCount) features and updated elevations"
            pendingOSMResult = nil
            centerlineGroups = []
            selectedMappingGroup = nil
            selectedMappingCenterline = nil
        } catch {
            logger.error("Elevation update failed after OSM import: \(error, privacy: .public)")
            osmImportStatus = "Elevation update failed: \(error.localizedDescription)"
        }
        isImportingOSM = false
        clearOSMStatusAfterDelay()
    }

    // MARK: - Center Map

    private func centerMapOnCourse() {
        let coord = course.location.coordinate
        if coord.latitude != 0 || coord.longitude != 0 {
            let region = MKCoordinateRegion(
                center: coord.clCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            )
            mapPosition = .region(region)
        }
    }

    private func clearStatusAfterDelay() {
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            statusMessage = ""
        }
    }

    private func clearOSMStatusAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            osmImportStatus = ""
        }
    }

}

// MARK: - Centerline Mapping

struct CenterlineGroup: Identifiable {
    let id = UUID()
    var label: String
    var centerlines: [OverpassAPIClient.ParsedCenterline]
    var assignedSubCourseIndex: Int?
}

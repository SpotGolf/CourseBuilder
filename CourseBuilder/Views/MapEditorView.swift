import SwiftUI
import AuthenticationServices
import CoreLocation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "MapEditor")

struct MapEditorView: View {
    @Binding var course: Course
    @ObservedObject var elevationWorker: ElevationWorker

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

    // Map state
    @AppStorage("imageryLayer") private var imageryLayer: ImageryLayer = .esri
    @State private var activeTool: ToolMode = .select
    @State private var statusMessage = ""
    @State private var statusTask: Task<Void, Never>?
    @State private var isDraggingVertex = false
    /// Read only in event handlers here, so camera and mouse updates do not redraw the editor.
    @State private var camera = MapCamera()
    @State private var tileLoader = TileLoader()
    @FocusState private var isMapFocused: Bool

    // OSM import state
    @State private var isImportingOSM = false
    @State private var osmImportStatus = ""
    @State private var pendingOSMResult: OverpassAPIClient.ParsedResult?
    @State private var centerlineGroups: [CenterlineGroup] = []
    @State private var selectedMappingGroup: Int?
    @State private var selectedMappingCenterline: Int? // index into the selected group's centerlines
    private var isMappingMode: Bool { pendingOSMResult != nil }

    // OSM publish state
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var osmBaseline: OSMBaseline?
    @State private var osmChanges: [OSMFeatureChange] = []
    @State private var isSigningInToOSM = false
    @State private var publishRequest: PublishRequest?
    @State private var publishedChangeset: (id: Int, url: URL)?
    private let baselineStore = OSMBaselineStore()

    /// What the publish dialog needs once the user is signed in.
    private struct PublishRequest: Identifiable {
        let id = UUID()
        let token: String
        let userName: String
        let changes: [OSMFeatureChange]
    }

    // Delete confirmation
    @State private var featureToDelete: Int?
    @State private var undoRecords: [FeatureUndoRecord] = []
    @State private var autoPolygon = AutoPolygonController()

    // Sidebar list heights
    @State private var holesCollapsed = false
    @State private var featuresCollapsed = false
    @State private var unassociatedCollapsed = false

    // Ignored features: taken out of the course, kept so they can be restored
    @State private var ignoredFeatures: [Feature] = []
    @State private var showsIgnored = false
    /// Rows selected in the Unassociated or Ignored list while no single feature is selected,
    /// for Ignore or Restore. See `UnassociatedSelection`.
    @State private var unassociatedMultiSelection: Set<Int> = []
    private let ignoredStore = IgnoredFeatureStore()

    var body: some View {
        let featureSets = HoleFeatureSets(course: course, hole: currentHole)
        VStack(spacing: 0) {
            toolbar(featureSets)
            Divider()

            HSplitView {
                if pendingOSMResult != nil {
                    mappingSidebar
                        .frame(minWidth: 220, maxWidth: 280)
                } else {
                    holeSidebar(featureSets)
                        .frame(minWidth: 200, maxWidth: 360)
                }

                VStack(spacing: 0) {
                    mapArea(featureSets)
                    statusBar(featureSets)
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
        .focusedSceneValue(\.mapCamera, camera)
        .onKeyPress(phases: .down) { press in
            // ⌘+ is shift-= on most keyboards, so also zoom in on plain ⌘=.
            guard press.key == KeyEquivalent("="), press.modifiers == .command else { return .ignored }
            camera.zoomIn()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "spac")) { press in
            guard !isMappingMode else { return .ignored }
            if let mode = ToolMode.allCases.first(where: { $0.shortcutKey == press.characters.first }),
               isToolAvailable(mode) {
                switchTool(to: mode)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "v")) { _ in
            imageryLayer = imageryLayer.next
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "e")) { _ in
            beginEditingSelectedFeature() ? .handled : .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "f")) { _ in
            fitSelectedFeature() ? .handled : .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[]")) { press in
            guard autoPolygon.session != nil else { return .ignored }
            autoPolygon.adjustTolerance(by: press.characters == "]" ? 1 : -1)
            return .handled
        }
        .onKeyPress(.escape) {
            if autoPolygon.isActive {
                autoPolygon.cancel()
                statusMessage = "Preview cancelled"
                clearStatusAfterDelay()
                return .handled
            }
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
        .onKeyPress(.upArrow) {
            selectAdjacentFeature(offset: -1)
        }
        .onKeyPress(.downArrow) {
            selectAdjacentFeature(offset: 1)
        }
        .onKeyPress(.leftArrow) {
            selectAdjacentPolygonVertex(offset: -1)
        }
        .onKeyPress(.rightArrow) {
            selectAdjacentPolygonVertex(offset: 1)
        }
        .onKeyPress(.return) {
            if autoPolygon.result != nil {
                acceptAutoPolygon()
            } else if !drawingVertices.isEmpty {
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
            return undoLastChange() ? .handled : .ignored
        }
        .navigationTitle("\(course.name) — \(course.location.cityStateDisplay)")
        .onAppear {
            centerMapOnCourse()
            isMapFocused = true
            loadIgnoredFeatures()
            loadOSMBaseline()
        }
        .onChange(of: course.features) {
            updateOSMChanges()
        }
        .sheet(item: $publishRequest) { request in
            PublishToOSMSheet(
                changes: request.changes,
                course: course,
                userName: request.userName
            ) { comment in
                try await publishToOSM(request, comment: comment)
            }
        }
    }

    // MARK: - Current Hole Helpers

    private var currentHole: Hole? {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count else { return nil }
        return course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex]
    }

    /// The points of the selected hole's centerline, or an empty path if it has none.
    private var currentCenterline: CoordinatePath {
        currentHole.map { course.centerlinePath(for: $0) } ?? []
    }

    // MARK: - Hole Sidebar

    // MARK: - Mapping Sidebar (shown during OSM import)

    private var mappingSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Map OSM Holes to Sub-Courses")
                .font(.headline)
                .padding(8)

            Text("Select a group to see its centerlines on the map, then assign it to a sub-course. Remove groups that are not part of this course.")
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
                                Spacer()
                                Button {
                                    removeCenterlineGroup(at: idx)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Leave these holes out of the import")
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
                    applyMappingAndImport()
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
        centerlineGroups.relabel()
        selectedMappingGroup = toGroup
        selectedMappingCenterline = nil
    }

    /// Leaves a group of OSM holes out of the import, such as holes from a different course.
    /// Their features are still imported, but no hole uses them.
    private func removeCenterlineGroup(at index: Int) {
        guard centerlineGroups.indices.contains(index) else { return }
        centerlineGroups.removeGroup(at: index)
        selectedMappingGroup = nil
        selectedMappingCenterline = nil
    }

    private func groupColor(for index: Int) -> Color {
        let colors: [Color] = [.red, .blue, .green, .orange, .purple, .cyan, .yellow, .pink, .mint]
        return colors[index % colors.count]
    }

    private func holeSidebar(_ featureSets: HoleFeatureSets) -> some View {
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
                                        if !isToolAvailable(activeTool) {
                                            switchTool(to: .select)
                                        }
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
                    let holeFeatures = sortedHoleFeatures(featureSets)
                    ScrollViewReader { proxy in
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
                            .id(feature.id)
                            .listRowBackground(
                                selectedFeatureID == feature.id
                                    ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2))
                                    : nil
                            )
                        }
                        // A feature picked on the map may be off screen in the list.
                        .onChange(of: selectedFeatureID) { _, featureID in
                            guard let featureID, holeFeatures.contains(where: { $0.id == featureID }) else { return }
                            withAnimation { proxy.scrollTo(featureID) }
                        }
                    }
                }
            }
            .frame(minHeight: 30)

            // Unassociated pane
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "Unassociated (\(featureSets.unassociated.count))", collapsed: $unassociatedCollapsed)
                if !unassociatedCollapsed {
                    unassociatedControls
                    ScrollViewReader { proxy in
                        List(showsIgnored ? ignoredFeatures : featureSets.unassociated, selection: unassociatedSelectionBinding(featureSets)) { feature in
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
                            .tag(feature.id)
                            .id(feature.id)
                        }
                        // A feature picked on the map or with the arrow keys may be off screen.
                        .onChange(of: selectedFeatureID) { _, featureID in
                            guard !showsIgnored, let featureID, featureSets.unassociatedIDs.contains(featureID) else { return }
                            withAnimation { proxy.scrollTo(featureID) }
                        }
                    }
                }
            }
            .frame(minHeight: 30)
        }
        .background(Color(.windowBackgroundColor))
    }

    /// Unassociated or Ignored, and Ignore or Restore for the selected rows.
    /// Two rows, so they fit the narrowest sidebar.
    private var unassociatedControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("List", selection: $showsIgnored) {
                Text("Unassociated").tag(false)
                Text("Ignored (\(ignoredFeatures.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: showsIgnored) { unassociatedMultiSelection = [] }

            HStack {
                Text(unassociatedRows.isEmpty ? "⌘-click to select several" : "\(unassociatedRows.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsIgnored {
                    Button("Restore") { restoreIgnoredFeatures() }
                        .disabled(unassociatedRows.isEmpty)
                        .help("Put the selected features back in the course")
                } else {
                    Button("Ignore") { ignoreSelectedFeatures() }
                        .disabled(unassociatedRows.isEmpty)
                        .help("Take the selected features out of the course")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Toolbar

    private func toolbar(_ featureSets: HoleFeatureSets) -> some View {
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
                    .disabled((isMappingMode && mode != .select) || !isToolAvailable(mode))
                }
            }

            // Feature type picker (for drawing)
            if activeTool == .drawPolygon || activeTool == .autoPolygon {
                Picker("Type", selection: $pendingFeatureType) {
                    ForEach(FeatureType.polygonTypes, id: \.self) { type in
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
                distanceReadout(featureSets)
            }

            Spacer()

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

            if osmChanges.contains(where: \.isSent) && !isMappingMode {
                Button {
                    Task { await startOSMPublish() }
                } label: {
                    HStack(spacing: 4) {
                        if isSigningInToOSM {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text("Publish to OSM")
                    }
                }
                .disabled(isSigningInToOSM || osmBaseline == nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Distance Readout

    private func distanceReadout(_ featureSets: HoleFeatureSets) -> some View {
        Group {
            let holeFeatures = featureSets.current
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

    private func mapArea(_ featureSets: HoleFeatureSets) -> some View {
        TileMapView(camera: camera, loader: tileLoader, layer: imageryLayer, panEnabled: !isDraggingVertex) {
            MapShapesLayer(camera: camera, shapes: mapShapes(featureSets))
            MapMarkersLayer(camera: camera, markers: mapMarkers)
        }
        .overlay {
            // Drag handle for selected feature vertex (only in edit mode)
            if activeTool == .select,
               isEditingFeature,
               let featureID = selectedFeatureID,
               let vertexIdx = selectedVertexIndex,
               let feature = course.findFeature(id: featureID),
               vertexIdx < feature.polygon.count {
                VertexDragHandle(
                    camera: camera,
                    coordinate: feature.polygon[vertexIdx],
                    onDragStarted: { isDraggingVertex = true },
                    onDragEnded: { translation in
                        updateVertexAfterDrag(featureID: featureID, vertexIndex: vertexIdx, translation: translation)
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
               vertexIdx < currentCenterline.count {
                VertexDragHandle(
                    camera: camera,
                    coordinate: currentCenterline[vertexIdx],
                    onDragStarted: { isDraggingVertex = true },
                    onDragEnded: { translation in
                        applyCenterlineVertexDrag(vertexIndex: vertexIdx, translation: translation)
                        isDraggingVertex = false
                    }
                )
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(count: 2)
                .exclusively(before: SpatialTapGesture())
                .onEnded { value in
                    let projection = camera.projection
                    switch value {
                    case .first(let tap):
                        // Double-clicking a polygon edge while editing adds a point; anywhere
                        // else it zooms in.
                        guard activeTool == .select,
                              isEditingFeature,
                              let featureID = selectedFeatureID,
                              let feature = course.findFeature(id: featureID),
                              let edge = PolygonEditorOperations.nearestEdge(
                                to: tap.location,
                                polygon: Array(feature.polygon),
                                convert: { projection.point(for: Coordinate($0)) }
                              ) else {
                            camera.zoomIn(anchor: tap.location)
                            return
                        }
                        addVertex(
                            projection.coordinate(at: edge.point),
                            to: featureID,
                            at: edge.insertionIndex
                        )
                    case .second(let tap):
                        handleMapTap(at: projection.coordinate(at: tap.location))
                    }
                }
        )
        .contextMenu {
            if let featureID = selectedFeatureID, let feature = course.findFeature(id: featureID) {
                Button("Fit to Imagery") { startFit(feature) }
                Divider()
                Button("Delete Feature", role: .destructive) { featureToDelete = featureID }
            }
        }
        .overlay(alignment: .topTrailing) {
            imageryLayerPicker
                .padding(8)
        }
    }

    /// Everything drawn on the map, bottom to top.
    private func mapShapes(_ featureSets: HoleFeatureSets) -> [MapShape] {
        var shapes: [MapShape] = []

        // Centerline groups during mapping mode
        if isMappingMode {
            for (groupIdx, group) in centerlineGroups.enumerated() {
                let isGroupSelected = selectedMappingGroup == groupIdx
                let color = groupColor(for: groupIdx)
                for (clIdx, cl) in group.centerlines.enumerated() {
                    let isCLSelected = isGroupSelected && selectedMappingCenterline == clIdx
                    shapes.append(MapShape(
                        kind: .polyline,
                        coordinates: cl.coordinates,
                        stroke: isCLSelected ? .white : color,
                        lineWidth: isCLSelected ? 5 : (isGroupSelected ? 3 : 1.5)
                    ))
                }
            }
        }

        // Feature polygons for current hole
        for feature in featureSets.current {
            let isSelected = selectedFeatureID == feature.id
            let isFitting = fittingFeatureID == feature.id
            let color = colorForFeatureType(feature.type)
            shapes.append(MapShape(
                kind: .polygon,
                coordinates: Array(feature.polygon),
                fill: color.opacity(isFitting ? 0 : (isSelected ? 0.5 : 0.3)),
                stroke: color.opacity(isFitting ? 0.4 : 1),
                lineWidth: isSelected ? 3 : 1.5
            ))
        }

        // Ignored features, while their list is shown
        if showsIgnored {
            for feature in ignoredFeatures {
                let isSelected = unassociatedMultiSelection.contains(feature.id)
                shapes.append(MapShape(
                    kind: .polygon,
                    coordinates: Array(feature.polygon),
                    fill: Color.gray.opacity(isSelected ? 0.4 : 0.15),
                    stroke: Color.gray,
                    lineWidth: isSelected ? 3 : 1,
                    dash: [4, 3]
                ))
            }
        }

        // Unassociated features (other-hole features are not drawn, to keep large courses readable)
        for feature in featureSets.unassociated {
            let isSelected = selectedFeatureID == feature.id
            let isFitting = fittingFeatureID == feature.id
            let color = colorForFeatureType(feature.type)
            shapes.append(MapShape(
                kind: .polygon,
                coordinates: Array(feature.polygon),
                fill: color.opacity(isFitting ? 0 : (isSelected ? 0.5 : 0.15)),
                stroke: color.opacity(0.5),
                lineWidth: isSelected ? 3 : 1
            ))
        }

        // Selected feature if it's not already visible (other-hole feature)
        if let featureID = selectedFeatureID,
           !featureSets.currentIDs.contains(featureID),
           !featureSets.unassociatedIDs.contains(featureID),
           let feature = course.findFeature(id: featureID) {
            let isFitting = fittingFeatureID == feature.id
            let color = colorForFeatureType(feature.type)
            shapes.append(MapShape(
                kind: .polygon,
                coordinates: Array(feature.polygon),
                fill: color.opacity(isFitting ? 0 : 0.5),
                stroke: color.opacity(isFitting ? 0.4 : 1),
                lineWidth: 3
            ))
        }

        // Centerline for current hole
        let centerline = currentCenterline
        if centerline.count >= 2 {
            shapes.append(MapShape(
                kind: .polyline,
                coordinates: Array(centerline),
                stroke: isCenterlineSelected ? .yellow : .white,
                lineWidth: isCenterlineSelected ? 3 : 2
            ))
        }

        // In-progress drawing
        if drawingVertices.count >= 2 {
            if activeTool == .drawPolygon {
                shapes.append(MapShape(
                    kind: .polygon,
                    coordinates: drawingVertices,
                    fill: colorForFeatureType(pendingFeatureType).opacity(0.2),
                    stroke: colorForFeatureType(pendingFeatureType),
                    lineWidth: 2,
                    dash: [5, 3]
                ))
            } else {
                shapes.append(MapShape(kind: .polyline, coordinates: drawingVertices, stroke: .white, lineWidth: 2, dash: [5, 3]))
            }
        }

        // Auto polygon / Fit to Imagery preview
        if let mode = autoPolygon.mode, let result = autoPolygon.result {
            shapes.append(MapShape(
                kind: .polygon,
                coordinates: result.polygon,
                fill: colorForFeatureType(mode.type).opacity(0.2),
                stroke: colorForFeatureType(mode.type),
                lineWidth: 2,
                dash: [5, 3]
            ))
        }

        return shapes
    }

    /// Vertex handles and drawing points, drawn above the shapes.
    private var mapMarkers: [MapMarker] {
        var markers: [MapMarker] = []

        // Vertex handles for selected centerline (in edit mode)
        let centerline = currentCenterline
        if isEditingCenterline, centerline.count >= 2 {
            for (index, coord) in centerline.enumerated() {
                let isSelected = selectedCenterlineVertexIndex == index
                markers.append(MapMarker(
                    id: "centerline-\(index)",
                    coordinate: coord,
                    diameter: 12,
                    fill: isSelected ? .white : .yellow,
                    stroke: .white,
                    strokeWidth: 1.5,
                    // The drag handle draws the point while it is dragged.
                    isHidden: isSelected && isDraggingVertex,
                    onTap: { selectedCenterlineVertexIndex = index }
                ))
            }
        }

        // Vertex handles for selected feature (only in edit mode)
        if isEditingFeature,
           let featureID = selectedFeatureID,
           let feature = course.findFeature(id: featureID) {
            for (index, coord) in feature.polygon.enumerated() {
                let isSelected = selectedVertexIndex == index
                markers.append(MapMarker(
                    id: "vertex-\(index)",
                    coordinate: coord,
                    diameter: 12,
                    fill: isSelected ? .white : .accentColor,
                    stroke: .white,
                    strokeWidth: 1.5,
                    // The drag handle draws the point while it is dragged.
                    isHidden: isSelected && isDraggingVertex,
                    onTap: { selectedVertexIndex = index }
                ))
            }
        }

        // Drawing vertex dots — first vertex is larger to indicate click-to-close
        for (index, coord) in drawingVertices.enumerated() {
            let id = "drawing-\(index)"
            if index == 0 && drawingVertices.count >= 3 && activeTool == .drawPolygon {
                markers.append(MapMarker(id: id, coordinate: coord, diameter: 14, fill: .white, stroke: colorForFeatureType(pendingFeatureType), strokeWidth: 2))
            } else if selectedDrawingVertexIndex == index {
                markers.append(MapMarker(id: id, coordinate: coord, diameter: 12, fill: .white, stroke: .yellow, strokeWidth: 2))
            } else {
                markers.append(MapMarker(id: id, coordinate: coord, diameter: 8, fill: .yellow, stroke: .white, strokeWidth: 1))
            }
        }

        return markers
    }

    private var imageryLayerPicker: some View {
        Menu {
            ForEach(ImageryLayer.allCases) { layer in
                Button(layer.name) { imageryLayer = layer }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.2.layers.3d")
                Text("(\(imageryLayer.shortName))")
                    .font(.system(size: 9, design: .monospaced))
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Imagery (v)")
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

                    revertControls(for: course.features[featureIndex])
                    multipolygonControls(for: course.features[featureIndex])
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
        case .autoPolygon:
            "Click inside a feature to trace it.\nPress Enter to add it."
        case .drawCenterline:
            "Click to place waypoints.\nPress Enter to finish centerline."
        }
    }

    // MARK: - Status Bar

    private func statusBar(_ featureSets: HoleFeatureSets) -> some View {
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

            // Background elevation lookup status
            if let elevationStatus = elevationWorker.statuses[course.id] {
                Text(elevationStatus.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // OSM import status
            if !osmImportStatus.isEmpty {
                Text(osmImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let publishedChangeset {
                Link("Published changeset \(publishedChangeset.id)", destination: publishedChangeset.url)
                    .font(.caption)
            }

            // Hole + feature count
            let subName = course.subCourses.indices.contains(selectedSubCourseIndex) ? course.subCourses[selectedSubCourseIndex].name : ""
            Text("\(subName) Hole \(currentHole?.number ?? 0)")
                .font(.caption)
            Text("\(featureSets.current.count) features")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    private var toolHint: String {
        autoPolygonHint ?? baseToolHint
    }

    private var autoPolygonHint: String? {
        guard autoPolygon.isActive || activeTool == .autoPolygon else { return nil }
        if autoPolygon.isLoading {
            return "Loading \(autoPolygon.layer.name)…"
        }
        if let mode = autoPolygon.mode, let result = autoPolygon.result, let tolerance = autoPolygon.tolerance {
            let toleranceText = String(format: "%.2f", tolerance)
            var text: String
            var controls: String
            switch mode {
            case .create(let type):
                text = "\(type.rawValue.capitalized) preview · \(result.polygon.count) pts"
                controls = "⇧-click add | ⌥-click remove | [ ] tolerance (\(toleranceText)) | Enter to add | Esc to cancel"
            case .fit:
                text = "Fit preview · \(result.polygon.count) pts"
                controls = "[ ] tolerance (\(toleranceText)) | Enter to accept | Esc to cancel"
            }
            if result.exceedsSafetyLimit { text += " — more than expected" }
            if result.areaDiffersFromOriginal { text += " — Result differs a lot from the original" }
            if autoPolygon.layer == .naip, let year = autoPolygon.imageryYear {
                controls += " | Imagery: USDA NAIP \(year)"
            } else {
                controls += " | Imagery: \(autoPolygon.layer.name)"
            }
            return "\(text) | \(controls)"
        }
        if let message = autoPolygon.message {
            return "\(message) | Esc to cancel"
        }
        return activeTool == .autoPolygon ? "Click inside a \(pendingFeatureType.rawValue) to trace it from \(imageryLayer.name)" : nil
    }

    private var baseToolHint: String {
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
        case .autoPolygon:
            ""
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
        case .centerline: 5
        }
    }

    private func colorForFeatureType(_ type: FeatureType) -> Color {
        switch type {
        case .fairway: .green
        case .green: .mint
        case .tee: .blue
        case .bunker: .yellow
        case .water: .cyan
        case .centerline: .white
        }
    }

    // MARK: - Tool Switching

    /// A hole has only one centerline, so the Centerline tool is off while the current hole has one.
    private func isToolAvailable(_ mode: ToolMode) -> Bool {
        mode != .drawCenterline || currentCenterline.isEmpty
    }

    private func switchTool(to mode: ToolMode) {
        if mode != activeTool {
            autoPolygon.cancel()
        }
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
        let modifiers = NSEvent.modifierFlags
        if autoPolygon.session != nil, modifiers.contains(.shift) {
            autoPolygon.add(at: coordinate)
            return
        }
        if autoPolygon.session != nil, modifiers.contains(.option) {
            autoPolygon.remove(at: coordinate)
            return
        }

        switch activeTool {
        case .select:
            selectFeatureAt(coordinate)
        case .autoPolygon:
            autoPolygon.startCreate(type: pendingFeatureType, at: coordinate, layer: imageryLayer)
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
        if isEditingCenterline {
            for (index, vertex) in currentCenterline.enumerated() {
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
        // are hit before large ones (fairways). Use bounding-box pre-filter to
        // avoid expensive point-in-polygon tests on distant features.
        let candidates = course.features
            .filter { feature in
                guard feature.type != .centerline else { return false }
                let lats = feature.polygon.map(\.lat)
                let lons = feature.polygon.map(\.lon)
                guard let minLat = lats.min(), let maxLat = lats.max(),
                      let minLon = lons.min(), let maxLon = lons.max() else { return false }
                return point.lat >= minLat && point.lat <= maxLat
                    && point.lon >= minLon && point.lon <= maxLon
            }
            .sorted { featureHitPriority($0.type) < featureHitPriority($1.type) }

        // Small features (tees, greens, bunkers, water) are hit before the centerline,
        // which usually runs through them. The centerline is hit before fairways, which
        // usually lie under it.
        let centerlinePriority = featureHitPriority(.fairway)
        if let feature = candidates.first(where: {
            featureHitPriority($0.type) < centerlinePriority && PolygonGeometry.contains(point, in: $0.polygon)
        }) {
            selectOrEditFeature(feature)
            return
        }

        // Check if tapping near the current hole's centerline
        let centerline = currentCenterline
        if centerline.count >= 2 {
            let dist = distanceToPolyline(from: point, polyline: centerline)
            let tapThreshold = camera.projection.latitudeDegrees(forPoints: 15)
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
        if let hoveredCoordinate = camera.hoveredCoordinate {
            selectedVertexIndex = PolygonEditorOperations.nearestVertexIndex(to: hoveredCoordinate, in: Array(feature.polygon))
        } else {
            selectedVertexIndex = nil
        }
        return true
    }

    /// The current hole's features in the order the Features list shows them.
    private func sortedHoleFeatures(_ featureSets: HoleFeatureSets) -> [Feature] {
        currentHole.map {
            FeatureSorter.sortedByDistanceFromGreen(featureSets.current, hole: $0, centerline: course.centerlinePath(for: $0))
        } ?? []
    }

    /// Up and down arrows move the selection through the Features or Unassociated list,
    /// whichever holds the selected feature, while it is not being edited.
    private func selectAdjacentFeature(offset: Int) -> KeyPress.Result {
        guard let featureID = selectedFeatureID, !isEditingFeature, !isEditingCenterline,
              drawingVertices.isEmpty, !autoPolygon.isActive, !isMappingMode else { return .ignored }
        let featureSets = HoleFeatureSets(course: course, hole: currentHole)
        let list = featureSets.currentIDs.contains(featureID)
            ? sortedHoleFeatures(featureSets).map(\.id)
            : featureSets.unassociated.map(\.id)
        guard let next = PolygonEditorOperations.adjacentFeatureID(current: featureID, in: list, offset: offset) else {
            return .ignored
        }
        selectedFeatureID = next
        selectedVertexIndex = nil
        return .handled
    }

    /// The rows selected in the Unassociated or Ignored list.
    private var unassociatedRows: Set<Int> {
        UnassociatedSelection.rows(
            selectedFeatureID: selectedFeatureID,
            multiSelection: unassociatedMultiSelection,
            unassociatedIDs: HoleFeatureSets(course: course, hole: currentHole).unassociatedIDs,
            showsIgnored: showsIgnored
        )
    }

    /// The Unassociated list's selection, worked out from the selected feature so the two never
    /// disagree. Picking one row selects that feature.
    private func unassociatedSelectionBinding(_ featureSets: HoleFeatureSets) -> Binding<Set<Int>> {
        Binding(
            get: {
                UnassociatedSelection.rows(
                    selectedFeatureID: selectedFeatureID,
                    multiSelection: unassociatedMultiSelection,
                    unassociatedIDs: featureSets.unassociatedIDs,
                    showsIgnored: showsIgnored
                )
            },
            set: { rows in
                switch UnassociatedSelection.outcome(of: rows, showsIgnored: showsIgnored) {
                case .selectFeature(let featureID):
                    unassociatedMultiSelection = []
                    // Clicking a row gives the list keyboard focus, and the list would take the
                    // arrow keys. Focus goes back to the editor so they move through features
                    // the same way as in the Features list.
                    isMapFocused = true
                    guard selectedFeatureID != featureID else { return }
                    selectedFeatureID = featureID
                    selectedVertexIndex = nil
                    isEditingFeature = false
                    activeTool = .select
                case .rows(let rows):
                    unassociatedMultiSelection = rows
                    if !rows.isEmpty || selectedFeatureID.map(featureSets.unassociatedIDs.contains) == true {
                        deselectAll()
                    }
                }
            }
        )
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
    }

    private func distanceToPolyline(from point: Coordinate, polyline: CoordinatePath) -> Double {
        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<(polyline.count - 1) {
            let dist = sqrt(PolygonGeometry.squaredDistanceToSegment(point, segStart: polyline[i], segEnd: polyline[i + 1]))
            if dist < minDist { minDist = dist }
        }
        return minDist
    }

    private func isClose(_ a: Coordinate, to b: Coordinate, pixels: CGFloat = 20) -> Bool {
        let threshold = camera.projection.latitudeDegrees(forPoints: pixels)
        return abs(a.lat - b.lat) < threshold && abs(a.lon - b.lon) < threshold
    }

    private func selectCenterlineAt(_ point: Coordinate) {
        var bestGroupIdx: Int?
        var bestClIdx: Int?
        var bestDist = Double.greatestFiniteMagnitude

        for (gIdx, group) in centerlineGroups.enumerated() {
            for (clIdx, cl) in group.centerlines.enumerated() {
                let dist = OSMImporter.distanceToPolyline(from: point, polyline: CoordinatePath(cl.coordinates))
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
            completePolygon()

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
            course.setCenterline(CoordinatePath(vertices), subCourseIndex: subCourseIndex, holeIndex: holeIndex)
            // A hole has only one centerline, so the tool is no longer available.
            activeTool = .select

        case .select, .autoPolygon:
            break
        }
    }

    /// Adds a feature to the course and the current hole. The elevation worker looks up its elevations.
    private func addFeature(type: FeatureType, polygon: [Coordinate]) -> Feature {
        // One write: during an event the course binding still returns the value from before
        // the event, so a second write would rebuild the course without the first change.
        PolygonEditorOperations.addFeature(
            type: type,
            polygon: polygon,
            subCourseIndex: selectedSubCourseIndex,
            holeIndex: selectedHoleIndex,
            to: &course
        )
    }

    /// Adds the drawn polygon to the course.
    private func completePolygon() {
        let featureType = pendingFeatureType
        let newFeature = addFeature(type: featureType, polygon: drawingVertices)

        selectedFeatureID = newFeature.id
        selectedVertexIndex = nil
        isEditingFeature = false
        drawingVertices = []
        selectedDrawingVertexIndex = nil
        activeTool = .select
        statusMessage = "Created \(featureType.rawValue) feature #\(newFeature.id)"
        clearStatusAfterDelay()
    }

    // MARK: - Vertex Dragging

    private func updateVertexAfterDrag(featureID: Int, vertexIndex: Int, translation: CGSize) {
        guard let featureIndex = course.features.firstIndex(where: { $0.id == featureID }),
              vertexIndex < course.features[featureIndex].polygon.count else { return }
        let movedCoordinate = moved(course.features[featureIndex].polygon[vertexIndex], by: translation)
        course.features[featureIndex].polygon.replace(at: vertexIndex, with: movedCoordinate)
    }

    private func applyCenterlineVertexDrag(vertexIndex: Int, translation: CGSize) {
        let centerline = currentCenterline
        guard vertexIndex < centerline.count else { return }
        let movedCoordinate = moved(centerline[vertexIndex], by: translation)
        course.updateCenterline(subCourseIndex: selectedSubCourseIndex, holeIndex: selectedHoleIndex) {
            $0.replace(at: vertexIndex, with: movedCoordinate)
        }
    }

    /// The coordinate `translation` points away on the map. The old elevation belongs to the
    /// old position, so it is dropped.
    private func moved(_ coordinate: Coordinate, by translation: CGSize) -> Coordinate {
        let projection = camera.projection
        let point = projection.point(for: coordinate)
        return projection.coordinate(at: CGPoint(x: point.x + translation.width, y: point.y + translation.height))
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
        let count = currentCenterline.count
        guard index < count else { return }
        if count <= 2 {
            statusMessage = "Cannot delete vertex — centerline needs at least 2 points"
            clearStatusAfterDelay()
            return
        }
        course.updateCenterline(subCourseIndex: selectedSubCourseIndex, holeIndex: selectedHoleIndex) {
            $0.remove(at: index)
        }
        let newCount = count - 1
        if index >= newCount {
            selectedCenterlineVertexIndex = newCount - 1
        }
    }

    private func deleteCenterline() {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count else { return }
        course.setCenterline([], subCourseIndex: selectedSubCourseIndex, holeIndex: selectedHoleIndex)
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
        undoRecords.append(.deleted(record))
        selectedFeatureID = nil
        selectedVertexIndex = nil
        isEditingFeature = false
    }

    @discardableResult
    private func undoLastChange() -> Bool {
        guard let record = undoRecords.popLast(),
              PolygonEditorOperations.undo(record, in: &course) else { return false }
        switch record {
        case .deleted(let deleted):
            selectedFeatureID = deleted.feature.id
            statusMessage = "Restored feature #\(deleted.feature.id)"
        case .replacedPolygon(let featureID, _):
            selectedFeatureID = featureID
            selectedVertexIndex = nil
            statusMessage = "Restored outline of feature #\(featureID)"
        case .reverted(let feature):
            selectedFeatureID = feature.id
            selectedVertexIndex = nil
            statusMessage = "Restored edits to feature #\(feature.id)"
        case .added(let featureID):
            if selectedFeatureID == featureID {
                selectedFeatureID = nil
                selectedVertexIndex = nil
                isEditingFeature = false
            }
            statusMessage = "Removed feature #\(featureID)"
        }
        clearStatusAfterDelay()
        return true
    }

    // MARK: - Auto Polygon / Fit to Imagery

    /// The feature whose Fit to Imagery preview is showing, if any.
    private var fittingFeatureID: Int? {
        if case .fit(let featureID, _, _) = autoPolygon.mode { return featureID }
        return nil
    }

    private func startFit(_ feature: Feature) {
        isEditingFeature = false
        selectedVertexIndex = nil
        autoPolygon.startFit(feature: feature, layer: imageryLayer)
    }

    private func fitSelectedFeature() -> Bool {
        guard activeTool == .select,
              let featureID = selectedFeatureID,
              let feature = course.findFeature(id: featureID) else { return false }
        startFit(feature)
        return true
    }

    private func acceptAutoPolygon() {
        guard let mode = autoPolygon.mode, let result = autoPolygon.result else { return }
        switch mode {
        case .create(let type):
            let newFeature = addFeature(type: type, polygon: result.polygon)
            undoRecords.append(.added(featureID: newFeature.id))
            selectedFeatureID = newFeature.id
            statusMessage = "Created \(type.rawValue) feature #\(newFeature.id) (\(result.polygon.count) pts)"
        case .fit(let featureID, _, let oldPolygon):
            guard let index = course.features.firstIndex(where: { $0.id == featureID }) else {
                autoPolygon.cancel()
                return
            }
            course.features[index].polygon = CoordinatePath(result.polygon)
            undoRecords.append(.replacedPolygon(featureID: featureID, oldPolygon: oldPolygon))
            selectedFeatureID = featureID
            statusMessage = "Fitted feature #\(featureID) (\(result.polygon.count) pts)"
        }
        autoPolygon.cancel()
        clearStatusAfterDelay()
    }

    // MARK: - OSM Import

    private func importFromOSM() async {
        isImportingOSM = true
        osmImportStatus = "Querying OpenStreetMap..."
        let client = OverpassAPIClient()
        let clubhouseCoord = course.location.coordinate
        logger.info("Starting OSM import for course '\(course.name, privacy: .public)' at \(clubhouseCoord.lat, privacy: .public), \(clubhouseCoord.lon, privacy: .public)")
        let searchBBox = OverpassAPIClient.boundingBox(around: clubhouseCoord, radiusMeters: 1000)
        do {
            let result = try await client.fetchFeatures(bbox: searchBBox)
            logger.info("Initial query: \(result.features.count, privacy: .public) features, \(result.centerlines.count, privacy: .public) centerlines, boundary: \(result.courseBoundary != nil, privacy: .public)")

            var finalResult = result
            if let bbox = OverpassAPIClient.boundaryBoundingBox(for: result.courseBoundary) {
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

    /// Adds the mapped OSM features and centerlines to the course. The elevation worker looks up their elevations.
    private func applyMappingAndImport() {
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
                    coordinates: centerline.coordinates,
                    osmID: centerline.osmID,
                    version: centerline.version
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

        course = importedCourse
        saveOSMBaseline(OSMBaseline(course: importedCourse, versions: Self.osmVersions(in: result)))
        logger.info("Imported \(importedFeatureCount, privacy: .public) features")
        osmImportStatus = "Imported \(importedFeatureCount) features"
        pendingOSMResult = nil
        centerlineGroups = []
        selectedMappingGroup = nil
        selectedMappingCenterline = nil
        clearOSMStatusAfterDelay()
    }

    // MARK: - Center Map

    private func centerMapOnCourse() {
        let coord = course.location.coordinate
        if coord.lat != 0 || coord.lon != 0 {
            camera.center = Coordinate(lat: coord.lat, lon: coord.lon)
            camera.zoom = 17.5
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

    // MARK: - OSM Publish

    /// Revert to OSM for a feature whose type or points differ from what OSM has.
    @ViewBuilder
    private func revertControls(for feature: Feature) -> some View {
        if let osmID = feature.osmID, let entry = osmBaseline?.entries[osmID], entry.differs(from: feature) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Button("Revert to OSM") {
                    revertToOSM(feature, entry: entry)
                }
                .help("Put back the type and points this feature has in OpenStreetMap")
            }
            .padding()
        }
    }

    private func revertToOSM(_ feature: Feature, entry: OSMBaseline.Entry) {
        guard let index = course.features.firstIndex(where: { $0.id == feature.id }) else { return }
        course.features[index] = entry.reverted(feature)
        undoRecords.append(.reverted(feature))
        selectedVertexIndex = nil
        isEditingFeature = false
        statusMessage = "Reverted feature #\(feature.id) to OSM"
        clearStatusAfterDelay()
    }

    /// Convert to Multipolygon for a fairway way with greens inside it, or the pending
    /// conversion with a way to cancel it.
    @ViewBuilder
    private func multipolygonControls(for feature: Feature) -> some View {
        if let baseline = osmBaseline {
            if let pending = OSMMultipolygon.pending(for: feature, in: baseline) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text(pending.innerOSMIDs.count == 1
                         ? "Becomes a multipolygon with the green inside it on the next publish."
                         : "Becomes a multipolygon with the \(pending.innerOSMIDs.count) greens inside it on the next publish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel Multipolygon") {
                        setPendingMultipolygon(nil, for: feature)
                    }
                }
                .padding()
            } else {
                let greens = OSMMultipolygon.containedGreens(in: feature, course: course)
                if !greens.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Button("Convert to Multipolygon") {
                            setPendingMultipolygon(
                                PendingMultipolygon(fairwayOSMID: feature.osmID ?? "", innerOSMIDs: greens.compactMap(\.osmID)),
                                for: feature
                            )
                        }
                        .help("On the next publish, make this fairway a multipolygon with the greens inside it as inner rings")
                    }
                    .padding()
                }
            }
        }
    }

    /// Records or removes the fairway's pending multipolygon.
    private func setPendingMultipolygon(_ pending: PendingMultipolygon?, for fairway: Feature) {
        guard var baseline = osmBaseline, let osmID = fairway.osmID else { return }
        baseline.pendingMultipolygons.removeAll { $0.fairwayOSMID == osmID }
        if let pending {
            baseline.pendingMultipolygons.append(pending)
        }
        saveOSMBaseline(baseline)
    }

    /// The OSM version of each imported element, by OSM ID.
    private static func osmVersions(in result: OverpassAPIClient.ParsedResult) -> [String: Int] {
        var versions: [String: Int] = [:]
        for feature in result.features {
            if let osmID = feature.osmID, let version = feature.version { versions[osmID] = version }
        }
        for centerline in result.centerlines {
            if let osmID = centerline.osmID, let version = centerline.version { versions[osmID] = version }
        }
        return versions
    }

    private func loadOSMBaseline() {
        do {
            osmBaseline = try baselineStore.loadOrCreate(for: course)
        } catch {
            logger.error("Could not load OSM baseline: \(error, privacy: .public)")
            osmImportStatus = "Could not load OSM changes: \(error.localizedDescription)"
        }
        updateOSMChanges()
    }

    private func saveOSMBaseline(_ baseline: OSMBaseline) {
        osmBaseline = baseline
        do {
            try baselineStore.save(baseline, courseID: course.id)
        } catch {
            logger.error("Could not save OSM baseline: \(error, privacy: .public)")
            osmImportStatus = "Could not save OSM changes: \(error.localizedDescription)"
        }
        updateOSMChanges()
    }

    private func updateOSMChanges() {
        let ignoredOSMIDs = Set(ignoredFeatures.compactMap(\.osmID))
        osmChanges = osmBaseline.map { OSMChangeDetector.changes(in: course, from: $0, ignoredOSMIDs: ignoredOSMIDs) } ?? []
    }

    // MARK: - Ignored Features

    private func loadIgnoredFeatures() {
        do {
            ignoredFeatures = try ignoredStore.load(courseID: course.id)
        } catch {
            logger.error("Could not load ignored features: \(error, privacy: .public)")
        }
    }

    private func saveIgnoredFeatures() {
        do {
            try ignoredStore.save(ignoredFeatures, courseID: course.id)
        } catch {
            logger.error("Could not save ignored features: \(error, privacy: .public)")
            statusMessage = "Could not save ignored features: \(error.localizedDescription)"
            clearStatusAfterDelay()
        }
    }

    private func ignoreSelectedFeatures() {
        let ids = unassociatedRows
        let before = ignoredFeatures.count
        let order = HoleFeatureSets(course: course, hole: currentHole).unassociated.map(\.id)
        IgnoredFeatures.ignore(ids, in: &course, ignored: &ignoredFeatures)
        unassociatedMultiSelection = []
        // The next unassociated feature is selected, so features can be ignored one after another.
        if let next = IgnoredFeatures.nextSelection(afterRemoving: ids, from: order) {
            deselectAll()
            selectedFeatureID = next
            activeTool = .select
            isMapFocused = true
        } else if let selectedFeatureID, ids.contains(selectedFeatureID) {
            deselectAll()
        }
        saveIgnoredFeatures()
        updateOSMChanges()
        statusMessage = "Ignored \(ignoredFeatures.count - before) feature(s)"
        clearStatusAfterDelay()
    }

    private func restoreIgnoredFeatures() {
        let ids = unassociatedRows
        let before = ignoredFeatures.count
        IgnoredFeatures.restore(ids, to: &course, ignored: &ignoredFeatures)
        unassociatedMultiSelection = []
        saveIgnoredFeatures()
        updateOSMChanges()
        statusMessage = "Restored \(before - ignoredFeatures.count) feature(s)"
        clearStatusAfterDelay()
    }

    /// Signs in if needed, then opens the publish dialog.
    private func startOSMPublish() async {
        isSigningInToOSM = true
        defer { isSigningInToOSM = false }
        do {
            let user = try await OSMAuth().signedInUser(authenticate: authenticateWithOSM)
            publishRequest = PublishRequest(token: user.token, userName: user.displayName, changes: osmChanges)
        } catch {
            logger.error("OSM sign in failed: \(error, privacy: .public)")
            osmImportStatus = "OSM sign in failed: \(error.localizedDescription)"
            clearOSMStatusAfterDelay()
        }
    }

    private func publishToOSM(_ request: PublishRequest, comment: String) async throws {
        guard let baseline = osmBaseline else { return }
        // A token revoked while the dialog is open gets a new sign in here, so the comment is kept.
        let result = try await OSMAuth().retryingAfterSignIn(token: request.token, authenticate: authenticateWithOSM) { token in
            try await OSMAPIClient(token: token).publish(request.changes, course: course, baseline: baseline, comment: comment)
        }
        course = result.course
        saveOSMBaseline(result.baseline)
        publishedChangeset = (result.changesetID, OSMServer.changesetURL(id: result.changesetID))
    }

    /// Shows the OSM sign-in page and returns its callback URL.
    private func authenticateWithOSM(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(
            using: url,
            callback: .customScheme(OSMAuth.callbackScheme),
            additionalHeaderFields: [:]
        )
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

extension [CenterlineGroup] {
    /// Removes a group and renumbers the groups after it.
    mutating func removeGroup(at index: Int) {
        remove(at: index)
        relabel()
    }

    /// Sets each group's label from its hole count and its place in the list.
    mutating func relabel() {
        for index in indices {
            self[index].label = "\(self[index].centerlines.count) holes (group \(index + 1))"
        }
    }
}

/// The rows selected in the Unassociated pane. Only one feature is selected at a time: one
/// selected row is the selected feature. Several rows, or rows in the Ignored list, are only for
/// Ignore or Restore and leave no feature selected.
enum UnassociatedSelection {
    enum Outcome: Equatable {
        /// Select this feature.
        case selectFeature(Int)
        /// Select no feature, and these rows.
        case rows(Set<Int>)
    }

    /// The rows to show selected. A selected feature decides them: its row if it is
    /// unassociated, otherwise none.
    static func rows(selectedFeatureID: Int?, multiSelection: Set<Int>, unassociatedIDs: Set<Int>, showsIgnored: Bool) -> Set<Int> {
        if showsIgnored { return multiSelection }
        if let selectedFeatureID { return unassociatedIDs.contains(selectedFeatureID) ? [selectedFeatureID] : [] }
        return multiSelection
    }

    /// What picking these rows in the list does.
    static func outcome(of rows: Set<Int>, showsIgnored: Bool) -> Outcome {
        if !showsIgnored, rows.count == 1, let featureID = rows.first { return .selectFeature(featureID) }
        return .rows(rows)
    }
}

/// The features the editor shows for the selected hole, worked out once per redraw.
struct HoleFeatureSets {
    let current: [Feature]
    let currentIDs: Set<Int>
    let unassociated: [Feature]
    let unassociatedIDs: Set<Int>

    init(course: Course, hole: Hole?) {
        currentIDs = Set(hole?.features ?? [])
        let assigned = Set(course.subCourses.flatMap(\.holes).flatMap(\.features))
            .union(course.centerlineFeatureIDs)
        var current: [Feature] = []
        var unassociated: [Feature] = []
        for feature in course.features {
            if currentIDs.contains(feature.id) {
                current.append(feature)
            }
            // Centerlines are drawn as lines with their hole, not as unassociated polygons.
            if !assigned.contains(feature.id), feature.type != .centerline {
                unassociated.append(feature)
            }
        }
        self.current = current
        self.unassociated = unassociated
        unassociatedIDs = Set(unassociated.map(\.id))
    }
}

/// An invisible drag target over a selected vertex.
///
/// It follows the camera and draws the point while it is dragged. Both change on every frame,
/// so they are kept here instead of in the editor, which would redraw the whole window.
private struct VertexDragHandle: View {
    let camera: MapCamera
    let coordinate: Coordinate
    let onDragStarted: () -> Void
    let onDragEnded: (CGSize) -> Void

    @State private var translation: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        let screenPoint = camera.projection.point(for: coordinate)
        ZStack {
            if isDragging {
                Circle()
                    .fill(Color.white)
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .offset(translation)
                    .allowsHitTesting(false)
            }
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onDragStarted()
                            }
                            translation = value.translation
                        }
                        .onEnded { value in
                            onDragEnded(value.translation)
                            translation = .zero
                            isDragging = false
                        }
                )
        }
        .position(screenPoint)
    }
}

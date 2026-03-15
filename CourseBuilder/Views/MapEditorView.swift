import SwiftUI
import MapKit
import CoreLocation
import os

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
    @EnvironmentObject var store: CourseStore
    @State var course: Course

    // Selection state
    @State private var selectedSubCourseIndex: Int = 0
    @State private var selectedHoleIndex: Int = 0
    @State private var selectedFeatureID: Int?
    @State private var selectedVertexIndex: Int?
    @State private var isEditingFeature = false

    // Drawing state
    @State private var drawingVertices: [Coordinate] = []
    @State private var pendingFeatureType: FeatureType = .fairway

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
    @State private var saveTask: Task<Void, Never>?
    @State private var statusTask: Task<Void, Never>?
    @State private var isDraggingVertex = false
    @State private var dragOffset: CGSize = .zero
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapViewSize: CGSize = .zero
    @FocusState private var isMapFocused: Bool

    // OSM import state
    @State private var isImportingOSM = false
    @State private var osmImportStatus = ""
    @State private var pendingOSMResult: OverpassAPIClient.ParsedResult?
    @State private var centerlineGroups: [CenterlineGroup] = []

    // Delete confirmation
    @State private var featureToDelete: Int?

    // Sidebar list heights
    @State private var holesCollapsed = false
    @State private var featuresCollapsed = false
    @State private var unassociatedCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HSplitView {
                holeSidebar
                    .frame(minWidth: 180, maxWidth: 220)

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
        .onKeyPress(.escape) {
            if !drawingVertices.isEmpty {
                drawingVertices = []
                statusMessage = "Drawing cancelled"
                clearStatusAfterDelay()
            } else if isEditingFeature {
                isEditingFeature = false
                selectedVertexIndex = nil
            } else {
                selectedFeatureID = nil
                selectedVertexIndex = nil
                isEditingFeature = false
            }
            return .handled
        }
        .onKeyPress(.delete) {
            deleteSelectedFeature()
            return .handled
        }
        .onKeyPress(KeyEquivalent("\u{7F}")) {
            deleteSelectedFeature()
            return .handled
        }
        .onKeyPress(.return) {
            if !drawingVertices.isEmpty {
                finishDrawing()
            } else if selectedFeatureID != nil && !isEditingFeature {
                isEditingFeature = true
            }
            return .handled
        }
        .navigationTitle("\(course.name) — \(course.location.city), \(course.location.state)")
        .onAppear {
            if let latest = store.courses.first(where: { $0.id == course.id }) {
                course = latest
            }
            centerMapOnCourse()
            isMapFocused = true
        }
        .onChange(of: course) {
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                saveCourse()
            }
        }
    }

    // MARK: - Current Hole Helpers

    private var currentHole: Hole? {
        guard selectedSubCourseIndex < course.subCourses.count,
              selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count else { return nil }
        return course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex]
    }

    private var currentHoleFeatures: [Feature] {
        guard let hole = currentHole else { return [] }
        return course.features(for: hole)
    }

    private var unassociatedFeatures: [Feature] {
        let allAssigned = Set(course.subCourses.flatMap(\.holes).flatMap(\.features))
        return course.features.filter { !allAssigned.contains($0.id) }
    }

    private var otherHoleFeatures: [Feature] {
        let currentIDs = Set(currentHole?.features ?? [])
        let allAssigned = Set(course.subCourses.flatMap(\.holes).flatMap(\.features))
        let otherIDs = allAssigned.subtracting(currentIDs)
        return course.features.filter { otherIDs.contains($0.id) }
    }

    // MARK: - Hole Sidebar

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
                                        selectedFeatureID = nil
                                        selectedVertexIndex = nil
                                        isEditingFeature = false
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
                // Render feature polygons for current hole
                ForEach(currentHoleFeatures) { feature in
                    let isSelected = selectedFeatureID == feature.id
                    MapPolygon(coordinates: feature.polygon.map(\.clCoordinate))
                        .foregroundStyle(colorForFeatureType(feature.type).opacity(isSelected ? 0.5 : 0.3))
                        .stroke(colorForFeatureType(feature.type), lineWidth: isSelected ? 3 : 1.5)
                }

                // Render features from other holes (dimmed)
                ForEach(otherHoleFeatures) { feature in
                    let isSelected = selectedFeatureID == feature.id
                    MapPolygon(coordinates: feature.polygon.map(\.clCoordinate))
                        .foregroundStyle(colorForFeatureType(feature.type).opacity(isSelected ? 0.5 : 0.1))
                        .stroke(colorForFeatureType(feature.type).opacity(0.3), lineWidth: isSelected ? 3 : 0.5)
                }

                // Render unassociated features
                ForEach(unassociatedFeatures) { feature in
                    let isSelected = selectedFeatureID == feature.id
                    MapPolygon(coordinates: feature.polygon.map(\.clCoordinate))
                        .foregroundStyle(colorForFeatureType(feature.type).opacity(isSelected ? 0.5 : 0.15))
                        .stroke(colorForFeatureType(feature.type).opacity(0.5), lineWidth: isSelected ? 3 : 1)
                }

                // Render centerline for current hole
                if let hole = currentHole, hole.centerline.count >= 2 {
                    MapPolyline(coordinates: hole.centerline.map(\.clCoordinate))
                        .stroke(.white, lineWidth: 2)
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

                // Drawing vertex dots
                ForEach(Array(drawingVertices.enumerated()), id: \.offset) { _, coord in
                    Annotation("", coordinate: coord.clCoordinate) {
                        Circle()
                            .fill(Color.yellow)
                            .stroke(Color.white, lineWidth: 1)
                            .frame(width: 8, height: 8)
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
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { mapViewSize = geometry.size }
                        .onChange(of: geometry.size) { _, newSize in mapViewSize = newSize }
                }
            }
            .overlay {
                // Drag handle for selected vertex (only in edit mode)
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
                                    applyVertexDrag(featureID: featureID, vertexIndex: vertexIdx, translation: value.translation)
                                    dragOffset = .zero
                                    isDraggingVertex = false
                                }
                        )
                }
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { tap in
                        guard let coord = proxy.convert(tap.location, from: .local) else { return }
                        let tapped = Coordinate(coord)
                        handleMapTap(at: tapped)
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
            Text("This will permanently remove this feature from the course and all holes.")
        }
        .sheet(isPresented: Binding(
            get: { pendingOSMResult != nil },
            set: { if !$0 { pendingOSMResult = nil; centerlineGroups = [] } }
        )) {
            CenterlineMappingSheet(
                groups: $centerlineGroups,
                subCourseNames: course.subCourses.map(\.name)
            ) {
                pendingOSMResult = nil
                centerlineGroups = []
            } onImport: {
                applyMappingAndImport()
            }
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
            if isEditingFeature && selectedVertexIndex != nil {
                "Drag vertex to move | Esc to stop editing | Del to remove feature"
            } else if isEditingFeature {
                "Click vertex to select | Esc to stop editing"
            } else if selectedFeatureID != nil {
                "Click again or Enter to edit | Esc to deselect | Del to remove feature"
            } else {
                "Click polygon to select"
            }
        case .drawPolygon:
            if drawingVertices.isEmpty {
                "Click to place first vertex"
            } else {
                "\(drawingVertices.count) vertices | Click to add | Enter to finish | Esc to cancel"
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
        }
        activeTool = mode
        if mode != .select {
            selectedFeatureID = nil
            selectedVertexIndex = nil
            isEditingFeature = false
        }
    }

    // MARK: - Map Tap Handling

    private func handleMapTap(at coordinate: Coordinate) {
        switch activeTool {
        case .select:
            selectFeatureAt(coordinate)
        case .drawPolygon:
            drawingVertices.append(coordinate)
        case .drawCenterline:
            drawingVertices.append(coordinate)
        }
    }

    private func selectFeatureAt(_ point: Coordinate) {
        // In edit mode, check if tapping near a vertex of the selected feature
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

        // Check if tap is inside any feature polygon of the current hole
        for feature in currentHoleFeatures {
            if PolygonGeometry.contains(point, in: feature.polygon) {
                if selectedFeatureID == feature.id && !isEditingFeature {
                    // Second click on selected polygon enters edit mode
                    isEditingFeature = true
                } else {
                    selectedFeatureID = feature.id
                    selectedVertexIndex = nil
                    isEditingFeature = false
                }
                return
            }
        }

        // Check unassociated features and features from other holes
        for feature in unassociatedFeatures + otherHoleFeatures {
            if PolygonGeometry.contains(point, in: feature.polygon) {
                if selectedFeatureID == feature.id && !isEditingFeature {
                    isEditingFeature = true
                } else {
                    selectedFeatureID = feature.id
                    selectedVertexIndex = nil
                    isEditingFeature = false
                }
                return
            }
        }

        // Nothing hit, deselect
        selectedFeatureID = nil
        selectedVertexIndex = nil
        isEditingFeature = false
    }

    private func isClose(_ a: Coordinate, to b: Coordinate) -> Bool {
        guard let region = visibleRegion else { return false }
        // Consider "close" as within ~20 pixels worth of degrees
        let threshold = region.span.latitudeDelta / (mapViewSize.height / 20.0)
        return abs(a.latitude - b.latitude) < threshold && abs(a.longitude - b.longitude) < threshold
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
            let newFeature = Feature(id: course.nextFeatureID, type: pendingFeatureType, polygon: drawingVertices)
            course.features.append(newFeature)

            // Associate with current hole
            if selectedSubCourseIndex < course.subCourses.count,
               selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count {
                course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].features.append(newFeature.id)
            }

            selectedFeatureID = newFeature.id
            selectedVertexIndex = nil
            drawingVertices = []
            statusMessage = "Created \(pendingFeatureType.rawValue) feature #\(newFeature.id)"
            clearStatusAfterDelay()

        case .drawCenterline:
            guard drawingVertices.count >= 2 else {
                statusMessage = "Need at least 2 waypoints for a centerline"
                clearStatusAfterDelay()
                return
            }
            if selectedSubCourseIndex < course.subCourses.count,
               selectedHoleIndex < course.subCourses[selectedSubCourseIndex].holes.count {
                course.subCourses[selectedSubCourseIndex].holes[selectedHoleIndex].centerline = drawingVertices
            }
            drawingVertices = []
            statusMessage = "Centerline set for hole \(currentHole?.number ?? 0)"
            clearStatusAfterDelay()

        case .select:
            break
        }
    }

    // MARK: - Vertex Dragging

    private func applyVertexDrag(featureID: Int, vertexIndex: Int, translation: CGSize) {
        guard let region = visibleRegion, mapViewSize.width > 0, mapViewSize.height > 0,
              let featureIndex = course.features.firstIndex(where: { $0.id == featureID }),
              vertexIndex < course.features[featureIndex].polygon.count else { return }
        let degreesPerPixelLat = region.span.latitudeDelta / mapViewSize.height
        let degreesPerPixelLng = region.span.longitudeDelta / mapViewSize.width
        course.features[featureIndex].polygon[vertexIndex].latitude -= translation.height * degreesPerPixelLat
        course.features[featureIndex].polygon[vertexIndex].longitude += translation.width * degreesPerPixelLng
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
        // Remove from course features
        course.features.removeAll { $0.id == id }
        // Remove from all hole features
        for subIdx in course.subCourses.indices {
            for holeIdx in course.subCourses[subIdx].holes.indices {
                course.subCourses[subIdx].holes[holeIdx].features.removeAll { $0 == id }
            }
        }
        selectedFeatureID = nil
        selectedVertexIndex = nil
        isEditingFeature = false
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
        OSMImporter.applyParsedResult(mappedResult, to: &course)
        logger.info("After apply: course has \(course.features.count, privacy: .public) features (was \(featureCountBefore, privacy: .public))")
        osmImportStatus = "Imported \(course.features.count - featureCountBefore) features"
        try? store.save(course)

        pendingOSMResult = nil
        centerlineGroups = []
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

    // MARK: - Save

    private func saveCourse() {
        do {
            try store.save(course)
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Centerline Mapping

struct CenterlineGroup: Identifiable {
    let id = UUID()
    let label: String
    let centerlines: [OverpassAPIClient.ParsedCenterline]
    var assignedSubCourseIndex: Int?
}

struct CenterlineMappingSheet: View {
    @Binding var groups: [CenterlineGroup]
    let subCourseNames: [String]
    let onCancel: () -> Void
    let onImport: () -> Void

    private var allAssigned: Bool {
        groups.allSatisfy { $0.assignedSubCourseIndex != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Map OSM Holes to Sub-Courses")
                .font(.headline)

            Text("OSM returned \(groups.count) group(s) of centerlines. Assign each group to the correct sub-course.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            ForEach($groups) { $group in
                HStack {
                    VStack(alignment: .leading) {
                        Text(group.label)
                            .font(.body.bold())
                        Text("\(group.centerlines.count) holes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 150, alignment: .leading)

                    Picker("", selection: $group.assignedSubCourseIndex) {
                        Text("Select...").tag(nil as Int?)
                        ForEach(Array(subCourseNames.enumerated()), id: \.offset) { idx, name in
                            Text(name).tag(idx as Int?)
                        }
                    }
                    .frame(width: 200)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    onImport()
                }
                .disabled(!allAssigned)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 400)
    }
}

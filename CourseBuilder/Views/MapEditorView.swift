import SwiftUI
import MapKit
import CoreLocation

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

    @State private var pins: [EditablePin] = []
    @State private var selectedSubCourseIndex: Int = 0
    @State private var selectedHole: Int = 1
    @State private var selectedPinID: UUID?
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
    @State private var toolClickIndex: Int = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var isDraggingPin = false
    @State private var dragOffset: CGSize = .zero
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapViewSize: CGSize = .zero
    @FocusState private var isMapFocused: Bool

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

                inspectorPanel
                    .frame(minWidth: 240, maxWidth: 300)
            }
        }
        .focusable()
        .focused($isMapFocused)
        .onKeyPress(characters: CharacterSet(charactersIn: "stgbw")) { press in
            if let mode = ToolMode.allCases.first(where: { $0.shortcutKey == press.characters.first }) {
                activeTool = mode
                toolClickIndex = 0
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "v")) { _ in
            mapStyleMode = mapStyleMode.next
            return .handled
        }
        .onKeyPress(.escape) {
            selectedPinID = nil
            return .handled
        }
        .onKeyPress(.delete) {
            deleteSelectedPin()
            return .handled
        }
        .onKeyPress(KeyEquivalent("\u{7F}")) {
            deleteSelectedPin()
            return .handled
        }
        .navigationTitle("\(course.name) — \(course.location.city), \(course.location.state)")
        .onAppear {
            if let latest = store.courses.first(where: { $0.id == course.id }) {
                course = latest
            }
            loadPinsFromCourse()
            centerMapOnCourse()
            isMapFocused = true
        }
        .onChange(of: pins) {
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                saveCourse()
            }
        }
    }

    // MARK: - Hole Sidebar

    private var holeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Holes")
                .font(.headline)
                .padding()

            List {
                ForEach(Array(course.subCourses.enumerated()), id: \.element.id) { subIdx, subCourse in
                    Section(subCourse.name) {
                        ForEach(subCourse.holes) { hole in
                            Button {
                                selectedSubCourseIndex = subIdx
                                selectedHole = hole.number
                                selectedPinID = nil
                            } label: {
                                HStack {
                                    Text("Hole \(hole.number)")
                                        .fontWeight(selectedSubCourseIndex == subIdx && selectedHole == hole.number ? .bold : .regular)
                                    Spacer()
                                    let count = pins.filter { $0.subCourseIndex == subIdx && $0.holeNumber == hole.number }.count
                                    Text("\(count) pins")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            // Pin list for selected hole
            let holePins = pins.filter { $0.subCourseIndex == selectedSubCourseIndex && $0.holeNumber == selectedHole }
            if !holePins.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pins - Hole \(selectedHole)")
                        .font(.subheadline.bold())
                        .padding(.horizontal)
                        .padding(.top, 8)

                    List(holePins) { pin in
                        Button {
                            selectedPinID = pin.id
                            activeTool = .select
                        } label: {
                            HStack {
                                Circle()
                                    .fill(colorForPinType(pin.pinType))
                                    .frame(width: 10, height: 10)
                                Text(pin.pinType.rawValue)
                                    .font(.caption)
                                if let teeName = pin.teeName, pin.pinType == .tee {
                                    Text("(\(teeName))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxHeight: 200)
                }
            }
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
                        activeTool = mode
                        toolClickIndex = 0
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

            Spacer()

            // Course name + distance (center)
            VStack(spacing: 2) {
                Text(course.name)
                    .font(.caption.bold())
                distanceReadout
            }

            Spacer()

            Spacer().frame(width: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Distance Readout

    private var distanceReadout: some View {
        Group {
            let holePins = pins.filter { $0.subCourseIndex == selectedSubCourseIndex && $0.holeNumber == selectedHole }
            let firstTee = holePins.first { $0.pinType == .tee }
            let greenMiddle = holePins.first { $0.pinType == .greenMiddle }

            if let tee = firstTee, let green = greenMiddle {
                let teeLocation = CLLocation(latitude: tee.coordinate.latitude, longitude: tee.coordinate.longitude)
                let greenLocation = CLLocation(latitude: green.coordinate.latitude, longitude: green.coordinate.longitude)
                let meters = teeLocation.distance(from: greenLocation)
                let yards = Int(meters * 1.09361)
                let scorecardYardage: Int = {
                    guard selectedSubCourseIndex < course.subCourses.count else { return 0 }
                    return course.subCourses[selectedSubCourseIndex]
                        .holes.first(where: { $0.number == selectedHole })?
                        .yardages.values.first ?? 0
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
                Text("Place tee + green pins for distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Map Area

    private var mapArea: some View {
        MapReader { proxy in
            Map(position: $mapPosition, interactionModes: isDraggingPin ? [.zoom, .rotate, .pitch] : .all) {
                ForEach(pinsForCurrentHole) { pin in
                    Annotation(pin.pinType.rawValue, coordinate: pin.coordinate.clCoordinate) {
                        pinMarker(for: pin)
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
                // Drag handle positioned over the selected pin
                if activeTool == .select,
                   let pinID = selectedPinID,
                   let pin = pinsForCurrentHole.first(where: { $0.id == pinID }),
                   let screenPoint = proxy.convert(pin.coordinate.clCoordinate, to: .local) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(screenPoint)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    isDraggingPin = true
                                    dragOffset = value.translation
                                }
                                .onEnded { value in
                                    applyDrag(to: pinID, translation: value.translation)
                                    dragOffset = .zero
                                    isDraggingPin = false
                                }
                        )
                }
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { tap in
                        if activeTool == .select {
                            selectedPinID = nil
                        } else if let coord = proxy.convert(tap.location, from: .local) {
                            placePin(at: Coordinate(coord))
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

    private func pinMarker(for pin: EditablePin) -> some View {
        let isSelected = selectedPinID == pin.id

        return Circle()
            .fill(colorForPinType(pin.pinType))
            .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
            .frame(width: 16, height: 16)
            .shadow(radius: 2)
            .padding(10)
            .contentShape(Circle())
            .offset(isSelected && isDraggingPin ? dragOffset : .zero)
            .onTapGesture {
                selectedPinID = pin.id
                activeTool = .select
            }
    }

    private var pinsForCurrentHole: [EditablePin] {
        pins.filter { $0.subCourseIndex == selectedSubCourseIndex && $0.holeNumber == selectedHole }
    }

    // MARK: - Inspector Panel

    private var inspectorPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector")
                .font(.headline)
                .padding()

            Divider()

            if let selectedPinID, let index = pins.firstIndex(where: { $0.id == selectedPinID }) {
                PinEditorView(
                    pin: $pins[index],
                    teeNames: course.tees.map(\.name),
                    onDelete: {
                        deletePin(at: index)
                    }
                )
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text("No pin selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(activeTool != .select
                         ? "Click map to place \(activeTool.rawValue.lowercased()) pin"
                         : "Click a pin to select it")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.windowBackgroundColor))
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

            // Hole + pin count
            let subName = course.subCourses.indices.contains(selectedSubCourseIndex) ? course.subCourses[selectedSubCourseIndex].name : ""
            Text("\(subName) Hole \(selectedHole)")
                .font(.caption)
            Text("\(pinsForCurrentHole.count) pins")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    private var toolHint: String {
        switch activeTool {
        case .select: "Click pin to select | Hold+drag to move | Esc to deselect | Del to remove"
        case .tee: "Click map to place tee"
        case .green:
            switch toolClickIndex {
            case 0: "Click map: green front"
            case 1: "Click map: green middle"
            default: "Click map: green back"
            }
        case .bunker:
            toolClickIndex == 0 ? "Click map: bunker front" : "Click map: bunker back"
        case .water:
            toolClickIndex == 0 ? "Click map: water front" : "Click map: water back"
        }
    }

    // MARK: - Pin Colors

    private func colorForPinType(_ pinType: PinType) -> Color {
        switch pinType {
        case .tee:
            return .blue
        case .greenFront, .greenMiddle, .greenBack:
            return .green
        case .bunkerFront, .bunkerBack:
            return .yellow
        case .waterFront, .waterBack:
            return .cyan
        }
    }

    // MARK: - Pin Management

    private func placePin(at coordinate: Coordinate) {
        let pinType = pinTypeForCurrentClick()
        let pin = EditablePin(
            id: UUID(),
            pinType: pinType,
            coordinate: coordinate,
            teeName: pinType == .tee ? course.tees.first?.name : nil,
            subCourseIndex: selectedSubCourseIndex,
            holeNumber: selectedHole
        )
        pins.append(pin)
        selectedPinID = pin.id
        toolClickIndex += 1

        // Reset click index when sequence is complete
        switch activeTool {
        case .green:
            if toolClickIndex >= 3 { toolClickIndex = 0 }
        case .bunker, .water:
            if toolClickIndex >= 2 { toolClickIndex = 0 }
        default:
            toolClickIndex = 0
        }
    }

    private func pinTypeForCurrentClick() -> PinType {
        switch activeTool {
        case .select:
            return .tee
        case .tee:
            return .tee
        case .green:
            switch toolClickIndex {
            case 0: return .greenFront
            case 1: return .greenMiddle
            default: return .greenBack
            }
        case .bunker:
            return toolClickIndex == 0 ? .bunkerFront : .bunkerBack
        case .water:
            return toolClickIndex == 0 ? .waterFront : .waterBack
        }
    }

    private func applyDrag(to pinID: UUID, translation: CGSize) {
        guard let region = visibleRegion, mapViewSize.width > 0, mapViewSize.height > 0,
              let index = pins.firstIndex(where: { $0.id == pinID }) else { return }
        let degreesPerPixelLat = region.span.latitudeDelta / mapViewSize.height
        let degreesPerPixelLng = region.span.longitudeDelta / mapViewSize.width
        pins[index].coordinate.latitude -= translation.height * degreesPerPixelLat
        pins[index].coordinate.longitude += translation.width * degreesPerPixelLng
    }

    private func deleteSelectedPin() {
        guard let selectedPinID,
              let index = pins.firstIndex(where: { $0.id == selectedPinID }) else { return }
        deletePin(at: index)
    }

    private func deletePin(at index: Int) {
        pins.remove(at: index)
        selectedPinID = nil
    }

    // MARK: - Load Pins from Course

    private func loadPinsFromCourse() {
        pins = []
        for (subIdx, subCourse) in course.subCourses.enumerated() {
            for hole in subCourse.holes {
                // Tee pins
                for (teeName, coord) in hole.tees {
                    pins.append(EditablePin(
                        id: UUID(),
                        pinType: .tee,
                        coordinate: coord,
                        teeName: teeName,
                        subCourseIndex: subIdx,
                        holeNumber: hole.number
                    ))
                }

                // Green pins
                if let green = hole.green {
                    pins.append(EditablePin(
                        id: UUID(),
                        pinType: .greenFront,
                        coordinate: green.front,
                        subCourseIndex: subIdx,
                        holeNumber: hole.number
                    ))
                    pins.append(EditablePin(
                        id: UUID(),
                        pinType: .greenMiddle,
                        coordinate: green.middle,
                        subCourseIndex: subIdx,
                        holeNumber: hole.number
                    ))
                    pins.append(EditablePin(
                        id: UUID(),
                        pinType: .greenBack,
                        coordinate: green.back,
                        subCourseIndex: subIdx,
                        holeNumber: hole.number
                    ))
                }

                // Feature pins
                for (featureIdx, feature) in hole.features.enumerated() {
                    switch feature.type {
                    case .bunker:
                        pins.append(EditablePin(
                            id: UUID(),
                            pinType: .bunkerFront,
                            coordinate: feature.front,
                            featureIndex: featureIdx,
                            subCourseIndex: subIdx,
                            holeNumber: hole.number
                        ))
                        pins.append(EditablePin(
                            id: UUID(),
                            pinType: .bunkerBack,
                            coordinate: feature.back,
                            featureIndex: featureIdx,
                            subCourseIndex: subIdx,
                            holeNumber: hole.number
                        ))
                    case .water:
                        pins.append(EditablePin(
                            id: UUID(),
                            pinType: .waterFront,
                            coordinate: feature.front,
                            featureIndex: featureIdx,
                            subCourseIndex: subIdx,
                            holeNumber: hole.number
                        ))
                        pins.append(EditablePin(
                            id: UUID(),
                            pinType: .waterBack,
                            coordinate: feature.back,
                            featureIndex: featureIdx,
                            subCourseIndex: subIdx,
                            holeNumber: hole.number
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Apply Pins to Course

    private func applyPinsToCourse() {
        for subIdx in course.subCourses.indices {
            for holeIdx in course.subCourses[subIdx].holes.indices {
                let holeNumber = course.subCourses[subIdx].holes[holeIdx].number
                let holePins = pins.filter { $0.subCourseIndex == subIdx && $0.holeNumber == holeNumber }

                // Tees
                var tees: [String: Coordinate] = [:]
                for pin in holePins where pin.pinType == .tee {
                    if let teeName = pin.teeName {
                        tees[teeName] = pin.coordinate
                    }
                }
                course.subCourses[subIdx].holes[holeIdx].tees = tees

                // Green
                let greenFront = holePins.first { $0.pinType == .greenFront }
                let greenMiddle = holePins.first { $0.pinType == .greenMiddle }
                let greenBack = holePins.first { $0.pinType == .greenBack }

                if let front = greenFront, let middle = greenMiddle, let back = greenBack {
                    course.subCourses[subIdx].holes[holeIdx].green = Green(
                        front: front.coordinate,
                        middle: middle.coordinate,
                        back: back.coordinate
                    )
                } else {
                    course.subCourses[subIdx].holes[holeIdx].green = nil
                }

                // Features
                var features: [Feature] = []

                let bunkerFronts = holePins.filter { $0.pinType == .bunkerFront }
                let bunkerBacks = holePins.filter { $0.pinType == .bunkerBack }
                for (front, back) in zip(bunkerFronts, bunkerBacks) {
                    features.append(Feature(type: .bunker, front: front.coordinate, back: back.coordinate))
                }

                let waterFronts = holePins.filter { $0.pinType == .waterFront }
                let waterBacks = holePins.filter { $0.pinType == .waterBack }
                for (front, back) in zip(waterFronts, waterBacks) {
                    features.append(Feature(type: .water, front: front.coordinate, back: back.coordinate))
                }

                course.subCourses[subIdx].holes[holeIdx].features = features
            }
        }
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

    // MARK: - Save

    private func saveCourse() {
        applyPinsToCourse()
        do {
            try store.save(course)
            statusMessage = "Saved"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}

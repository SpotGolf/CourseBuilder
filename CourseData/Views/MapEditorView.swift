import SwiftUI
import MapKit
import CoreLocation

struct MapEditorView: View {
    @EnvironmentObject var store: CourseStore
    @State var course: Course

    @State private var pins: [EditablePin] = []
    @State private var selectedHole: Int = 1
    @State private var selectedPinID: UUID?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isDetecting = false
    @State private var statusMessage = ""

    var body: some View {
        HSplitView {
            holeSidebar
                .frame(minWidth: 180, maxWidth: 220)

            VStack(spacing: 0) {
                toolbar
                mapArea
                statusBar
            }
        }
        .onAppear {
            loadPinsFromCourse()
            centerMapOnCourse()
        }
    }

    // MARK: - Hole Sidebar

    private var holeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Holes")
                .font(.headline)
                .padding()

            List(course.holes) { hole in
                Button {
                    selectedHole = hole.number
                    selectedPinID = nil
                } label: {
                    HStack {
                        Text("Hole \(hole.number)")
                            .fontWeight(selectedHole == hole.number ? .bold : .regular)
                        Spacer()
                        let count = pins.filter { $0.holeNumber == hole.number }.count
                        Text("\(count) pins")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Pin list for selected hole
            let holePins = pins.filter { $0.holeNumber == selectedHole }
            if !holePins.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pins - Hole \(selectedHole)")
                        .font(.subheadline.bold())
                        .padding(.horizontal)
                        .padding(.top, 8)

                    List(holePins) { pin in
                        Button {
                            selectedPinID = pin.id
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
        HStack {
            Text(course.name)
                .font(.title3.bold())

            Spacer()

            distanceReadout

            Spacer()

            Button("Auto-Detect") {
                runAutoDetect()
            }
            .disabled(isDetecting)

            if isDetecting {
                ProgressView()
                    .scaleEffect(0.7)
            }

            Button("Export JSON...") {
                exportJSON()
            }

            Button("Save") {
                saveCourse()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Distance Readout

    private var distanceReadout: some View {
        Group {
            let holePins = pins.filter { $0.holeNumber == selectedHole }
            let firstTee = holePins.first { $0.pinType == .tee }
            let greenMiddle = holePins.first { $0.pinType == .greenMiddle }

            if let tee = firstTee, let green = greenMiddle {
                let teeLocation = CLLocation(latitude: tee.coordinate.latitude, longitude: tee.coordinate.longitude)
                let greenLocation = CLLocation(latitude: green.coordinate.latitude, longitude: green.coordinate.longitude)
                let meters = teeLocation.distance(from: greenLocation)
                let yards = Int(meters * 1.09361)
                let scorecardYardage = course.holes.first(where: { $0.number == selectedHole })?.yardages.values.first ?? 0

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
            Map(position: $mapPosition) {
                ForEach(pinsForCurrentHole) { pin in
                    Annotation(pin.pinType.rawValue, coordinate: pin.coordinate.clCoordinate) {
                        pinMarker(for: pin)
                    }
                }
            }
            .mapStyle(.imagery(elevation: .realistic))
            .onTapGesture(count: 2) { position in
                if let coord = proxy.convert(position, from: .local) {
                    addNewPin(at: Coordinate(coord))
                }
            }
        }
    }

    private func pinMarker(for pin: EditablePin) -> some View {
        Circle()
            .fill(colorForPinType(pin.pinType))
            .stroke(selectedPinID == pin.id ? Color.white : Color.clear, lineWidth: 2)
            .frame(width: 16, height: 16)
            .shadow(radius: 2)
            .onTapGesture {
                selectedPinID = pin.id
            }
    }

    private var pinsForCurrentHole: [EditablePin] {
        pins.filter { $0.holeNumber == selectedHole }
    }

    // MARK: - Pin Inspector (right side)

    // Using a popover anchored to the selected pin in the sidebar instead of a floating panel
    // This is handled via the sidebar pin selection — when selectedPinID is set, we show the editor

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            if let selectedPinID, let index = pins.firstIndex(where: { $0.id == selectedPinID }) {
                PinEditorView(
                    pin: $pins[index],
                    teeNames: course.tees.map(\.name),
                    onDelete: {
                        pins.remove(at: index)
                        self.selectedPinID = nil
                    }
                )
            } else {
                Text(statusMessage.isEmpty ? "Double-click map to place a pin" : statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .background(Color(.windowBackgroundColor))
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

    private func addNewPin(at coordinate: Coordinate) {
        let pin = EditablePin(
            id: UUID(),
            pinType: .tee,
            coordinate: coordinate,
            teeName: course.tees.first?.name,
            holeNumber: selectedHole
        )
        pins.append(pin)
        selectedPinID = pin.id
    }

    // MARK: - Load Pins from Course

    private func loadPinsFromCourse() {
        pins = []
        for hole in course.holes {
            // Tee pins
            for (teeName, coord) in hole.tees {
                pins.append(EditablePin(
                    id: UUID(),
                    pinType: .tee,
                    coordinate: coord,
                    teeName: teeName,
                    holeNumber: hole.number
                ))
            }

            // Green pins
            if let green = hole.green {
                pins.append(EditablePin(
                    id: UUID(),
                    pinType: .greenFront,
                    coordinate: green.front,
                    holeNumber: hole.number
                ))
                pins.append(EditablePin(
                    id: UUID(),
                    pinType: .greenMiddle,
                    coordinate: green.middle,
                    holeNumber: hole.number
                ))
                pins.append(EditablePin(
                    id: UUID(),
                    pinType: .greenBack,
                    coordinate: green.back,
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
                        holeNumber: hole.number
                    ))
                    pins.append(EditablePin(
                        id: UUID(),
                        pinType: .bunkerBack,
                        coordinate: feature.back,
                        featureIndex: featureIdx,
                        holeNumber: hole.number
                    ))
                case .water:
                    pins.append(EditablePin(
                        id: UUID(),
                        pinType: .waterFront,
                        coordinate: feature.front,
                        featureIndex: featureIdx,
                        holeNumber: hole.number
                    ))
                    pins.append(EditablePin(
                        id: UUID(),
                        pinType: .waterBack,
                        coordinate: feature.back,
                        featureIndex: featureIdx,
                        holeNumber: hole.number
                    ))
                }
            }
        }
    }

    // MARK: - Apply Pins to Course

    private func applyPinsToCourse() {
        for i in course.holes.indices {
            let holeNumber = course.holes[i].number
            let holePins = pins.filter { $0.holeNumber == holeNumber }

            // Tees
            var tees: [String: Coordinate] = [:]
            for pin in holePins where pin.pinType == .tee {
                if let teeName = pin.teeName {
                    tees[teeName] = pin.coordinate
                }
            }
            course.holes[i].tees = tees

            // Green
            let greenFront = holePins.first { $0.pinType == .greenFront }
            let greenMiddle = holePins.first { $0.pinType == .greenMiddle }
            let greenBack = holePins.first { $0.pinType == .greenBack }

            if let front = greenFront, let middle = greenMiddle, let back = greenBack {
                course.holes[i].green = Green(
                    front: front.coordinate,
                    middle: middle.coordinate,
                    back: back.coordinate
                )
            } else {
                course.holes[i].green = nil
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

            course.holes[i].features = features
        }
    }

    // MARK: - Center Map

    private func centerMapOnCourse() {
        let coord = course.location.coordinate
        if coord.latitude != 0 || coord.longitude != 0 {
            let region = MKCoordinateRegion(
                center: coord.clCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            mapPosition = .region(region)
        }
    }

    // MARK: - Auto-Detect

    private func runAutoDetect() {
        isDetecting = true
        statusMessage = "Detecting features..."

        Task {
            do {
                let coord = course.location.coordinate
                let region = MKCoordinateRegion(
                    center: coord.clCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                )
                let detector = FeatureDetector()
                let detected = try await detector.detect(in: region)

                for feature in detected {
                    let pinType: PinType
                    switch feature.kind {
                    case .green:
                        pinType = .greenMiddle
                    case .teeBox:
                        pinType = .tee
                    }

                    let pin = EditablePin(
                        id: UUID(),
                        pinType: pinType,
                        coordinate: feature.coordinate,
                        teeName: pinType == .tee ? course.tees.first?.name : nil,
                        holeNumber: selectedHole
                    )
                    pins.append(pin)
                }

                statusMessage = "Detected \(detected.count) features"
            } catch {
                statusMessage = "Detection failed: \(error.localizedDescription)"
            }
            isDetecting = false
        }
    }

    // MARK: - Export JSON

    private func exportJSON() {
        applyPinsToCourse()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(course.id).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(course)
            try data.write(to: url)
            statusMessage = "Exported to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
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

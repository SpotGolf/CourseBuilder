import SwiftUI

enum ToolMode: String, CaseIterable {
    case select = "Select"
    case tee = "Tee"
    case green = "Green"
    case bunker = "Bunker"
    case water = "Water"

    var shortcutKey: Character {
        switch self {
        case .select: "s"
        case .tee: "t"
        case .green: "g"
        case .bunker: "b"
        case .water: "w"
        }
    }

    var defaultPinType: PinType? {
        switch self {
        case .select: nil
        case .tee: .tee
        case .green: .greenFront
        case .bunker: .bunkerFront
        case .water: .waterFront
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .tee: "figure.golf"
        case .green: "circle.circle"
        case .bunker: "square.on.square.dashed"
        case .water: "drop"
        }
    }
}

enum PinType: String, CaseIterable {
    case tee = "Tee"
    case greenFront = "Green (Front)"
    case greenMiddle = "Green (Middle)"
    case greenBack = "Green (Back)"
    case bunkerFront = "Bunker (Front)"
    case bunkerBack = "Bunker (Back)"
    case waterFront = "Water (Front)"
    case waterBack = "Water (Back)"
}

struct EditablePin: Identifiable, Equatable {
    let id: UUID
    var pinType: PinType
    var coordinate: Coordinate
    var teeName: String?
    var featureIndex: Int?
    var holeNumber: Int

    static func == (lhs: EditablePin, rhs: EditablePin) -> Bool {
        lhs.id == rhs.id
            && lhs.pinType == rhs.pinType
            && lhs.coordinate == rhs.coordinate
            && lhs.teeName == rhs.teeName
            && lhs.holeNumber == rhs.holeNumber
    }
}

struct PinEditorView: View {
    @Binding var pin: EditablePin
    let teeNames: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hole \(pin.holeNumber)").font(.headline)

            Picker("Type", selection: $pin.pinType) {
                ForEach(PinType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }

            if pin.pinType == .tee {
                Picker("Tee", selection: Binding(
                    get: { pin.teeName ?? "" },
                    set: { pin.teeName = $0 }
                )) {
                    ForEach(teeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            HStack {
                Text("Lat:")
                TextField("Latitude", value: $pin.coordinate.latitude, format: .number)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Lon:")
                TextField("Longitude", value: $pin.coordinate.longitude, format: .number)
                    .textFieldStyle(.roundedBorder)
            }

            Button("Delete", role: .destructive, action: onDelete)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

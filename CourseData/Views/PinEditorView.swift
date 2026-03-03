import SwiftUI

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
        .frame(width: 250)
    }
}

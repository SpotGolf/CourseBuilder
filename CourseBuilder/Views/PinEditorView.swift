import SwiftUI

enum ToolMode: String, CaseIterable {
    case select = "Select"
    case drawPolygon = "Polygon"
    case drawCenterline = "Centerline"

    var shortcutKey: Character {
        switch self {
        case .select: "s"
        case .drawPolygon: "p"
        case .drawCenterline: "c"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .drawPolygon: "pentagon"
        case .drawCenterline: "line.diagonal"
        }
    }
}

struct FeatureEditorView: View {
    @Binding var feature: Feature
    @Binding var hole: Hole
    var teeNames: [String] = []
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feature #\(feature.id)")
                .font(.headline)

            Picker("Type", selection: Binding(
                get: { feature.type },
                set: { newType in
                    let updated = Feature(id: feature.id, type: newType, polygon: feature.polygon)
                    feature = updated
                    if newType != .tee {
                        // Remove from tees if type changed away from tee
                        for (name, id) in hole.tees where id == feature.id {
                            hole.tees.removeValue(forKey: name)
                        }
                    }
                }
            )) {
                ForEach(FeatureType.allCases, id: \.self) { type in
                    Text(type.rawValue.capitalized).tag(type)
                }
            }

            if feature.type == .tee, !teeNames.isEmpty {
                Text("Tees")
                    .font(.subheadline.bold())
                ForEach(teeNames, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { hole.tees[name] == feature.id },
                        set: { isOn in
                            if isOn {
                                hole.tees[name] = feature.id
                            } else {
                                hole.tees.removeValue(forKey: name)
                            }
                        }
                    ))
                }
            }

            let centroid = PolygonGeometry.centroid(of: feature.polygon)
            let area = PolygonGeometry.area(of: feature.polygon)

            HStack {
                Text("Vertices: \(feature.polygon.count)")
                    .font(.caption)
                Spacer()
                Text(String(format: "Area: %.2e", area))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            HStack {
                Text(String(format: "Centroid: %.6f, %.6f", centroid.latitude, centroid.longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Vertices")
                .font(.subheadline.bold())

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(feature.polygon.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            Text("\(index)")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            TextField("Lat", value: $feature.polygon[index].latitude, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            TextField("Lon", value: $feature.polygon[index].longitude, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                        }
                    }
                }
            }

            Button("Delete Feature", role: .destructive, action: onDelete)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

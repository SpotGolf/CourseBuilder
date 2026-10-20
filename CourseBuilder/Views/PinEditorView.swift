import SwiftUI
import CourseDataSwift

enum ToolMode: String, CaseIterable {
    case select = "Select"
    case drawPolygon = "Polygon"
    case autoPolygon = "Auto"
    case drawCenterline = "Centerline"

    var shortcutKey: Character {
        switch self {
        case .select: "s"
        case .drawPolygon: "p"
        case .autoPolygon: "a"
        case .drawCenterline: "c"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .drawPolygon: "pentagon"
        case .autoPolygon: "wand.and.stars"
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

            let centroid = feature.center
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
                Text(String(format: "Centroid: %.6f, %.6f", centroid.lat, centroid.lon))
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
                            TextField("Lat", value: vertexBinding(index, \.lat), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            TextField("Lon", value: vertexBinding(index, \.lon), format: .number)
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

    /// A binding to one value of a polygon vertex. A path's points can't be changed in place, so
    /// setting it replaces the polygon.
    private func vertexBinding(_ index: Int, _ keyPath: WritableKeyPath<Coordinate, Double>) -> Binding<Double> {
        Binding(
            get: { feature.polygon[index][keyPath: keyPath] },
            set: { value in
                var points = Array(feature.polygon)
                points[index][keyPath: keyPath] = value
                feature.polygon = CoordinatePath(points)
            }
        )
    }
}

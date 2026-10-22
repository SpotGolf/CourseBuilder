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
    let onDelete: () -> Void

    /// The feature's current tags in OSM. Nil while loading.
    @State private var osmTags: [String: String]?
    @State private var osmTagsFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feature #\(feature.id)")
                .font(.headline)

            Picker("Type", selection: Binding(
                get: { feature.type },
                set: { newType in
                    feature = Feature(id: feature.id, type: newType, polygon: feature.polygon, osmID: feature.osmID)
                }
            )) {
                ForEach(FeatureType.polygonTypes, id: \.self) { type in
                    Text(type.rawValue.capitalized).tag(type)
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

            if let osmID = feature.osmID {
                osmMetadata(osmID: osmID)
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
        .task(id: feature.osmID) {
            await loadOSMTags()
        }
    }

    /// The OSM ID, linked to its page, and the element's tags.
    private func osmMetadata(osmID: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("OSM:")
                if let url = OSMServer.elementURL(osmID: osmID) {
                    Link(osmID, destination: url)
                } else {
                    Text(osmID)
                }
            }
            if let osmTags {
                if osmTags.isEmpty {
                    Text("No tags")
                } else {
                    ForEach(osmTags.sorted { $0.key < $1.key }, id: \.key) { tag in
                        Text("\(tag.key)=\(tag.value)")
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text(osmTagsFailed ? "Tags could not be loaded" : "Loading tags…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func loadOSMTags() async {
        osmTags = nil
        osmTagsFailed = false
        guard let osmID = feature.osmID else { return }
        do {
            osmTags = try await OSMAPIClient.tags(of: osmID)
        } catch {
            osmTagsFailed = !Task.isCancelled
        }
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

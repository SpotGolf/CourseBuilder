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

    var menuTitle: String {
        switch self {
        case .select: "Select"
        case .drawPolygon: "Draw Polygon"
        case .autoPolygon: "Auto Polygon"
        case .drawCenterline: "Draw Centerline"
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

/// The inspector for a selected feature: type, then General, OSM, Vertices, and Actions sections.
/// Points are edited on the map, so the vertex list is read only.
struct FeatureEditorView<Actions: View>: View {
    @Binding var feature: Feature
    /// What OSM had for the feature the last time the app and OSM agreed.
    let osmEntry: OSMBaseline.Entry?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            GroupBox("General") {
                general
            }

            if let osmID = feature.osmID {
                GroupBox("OSM") {
                    osmMetadata(osmID: osmID)
                }
            }

            GroupBox("Vertices") {
                vertices
            }
            .frame(maxHeight: .infinity)

            GroupBox("Actions") {
                VStack(alignment: .leading, spacing: 8) {
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var general: some View {
        let centroid = feature.center
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                Text("Vertices").foregroundStyle(.secondary)
                Text("\(feature.polygon.count)")
            }
            GridRow {
                Text("Area").foregroundStyle(.secondary)
                Text(String(format: "%.2e", PolygonGeometry.area(of: feature.polygon)))
            }
            GridRow {
                Text("Centroid").foregroundStyle(.secondary)
                Text(String(format: "%.6f, %.6f", centroid.lat, centroid.lon))
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The OSM ID, linked to its page, the element's version and tags, and a relation's members.
    private func osmMetadata(osmID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("ID").foregroundStyle(.secondary)
                    elementLink(osmID)
                }
                if let version = osmEntry?.version {
                    GridRow {
                        Text("Version").foregroundStyle(.secondary)
                        Text("\(version)")
                    }
                }
            }

            if let tags = osmEntry?.tags {
                Text("Tags").font(.caption.bold())
                if tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                } else {
                    ForEach(tags.sorted { $0.key < $1.key }, id: \.key) { tag in
                        Text("\(tag.key)=\(tag.value)")
                            .textSelection(.enabled)
                    }
                }

                if let members = osmEntry?.members {
                    Text("Members").font(.caption.bold())
                    if members.isEmpty {
                        Text("No members").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                            ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                                GridRow {
                                    elementLink("\(member.type.prefix(1))\(member.ref)")
                                    Text(member.role.isEmpty ? "no role" : member.role)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Tags not read from OSM yet")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func elementLink(_ osmID: String) -> some View {
        if let url = OSMServer.elementURL(osmID: osmID) {
            Link(osmID, destination: url)
        } else {
            Text(osmID)
        }
    }

    private var vertices: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(feature.polygon.enumerated()), id: \.offset) { index, point in
                    HStack(spacing: 8) {
                        Text("\(index)")
                            .frame(width: 24, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.7f, %.7f", point.lat, point.lon))
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 60)
    }
}

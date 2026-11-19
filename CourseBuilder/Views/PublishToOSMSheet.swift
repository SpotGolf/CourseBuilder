import SwiftUI
import CourseDataSwift

/// The comment dialog for publishing feature changes to OSM.
struct PublishToOSMSheet: View {
    let changes: [OSMFeatureChange]
    let course: Course
    let userName: String
    /// Publishes with the given comment. Throws to keep the dialog open.
    let publish: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var comment: String
    @State private var selection: TextSelection?
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var conflicts: Set<String> = []
    @FocusState private var isCommentFocused: Bool

    init(
        changes: [OSMFeatureChange],
        course: Course,
        userName: String,
        publish: @escaping (String) async throws -> Void
    ) {
        self.changes = changes
        self.course = course
        self.userName = userName
        self.publish = publish
        let comment = Self.defaultComment(userName: userName)
        _comment = State(initialValue: comment)
        _selection = State(initialValue: TextSelection(insertionPoint: comment.startIndex))
    }

    /// Two blank lines for the user's comment, then the footer.
    static func defaultComment(userName: String, date: Date = Date()) -> String {
        "\n\nEdited by \(userName) using CourseBuilder - \(date.ISO8601Format())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish to OSM")
                .font(.headline)

            Table(rows) {
                TableColumn("Action") { cell($0.action, in: $0) }
                    .width(80)
                TableColumn("Type") { cell($0.type, in: $0) }
                    .width(60)
                TableColumn("Feature") { cell($0.feature, in: $0) }
                    .width(55)
                TableColumn("Hole") { cell($0.hole, in: $0) }
                    .width(50)
                TableColumn("OSM ID") { cell($0.osmID, in: $0).monospaced() }
                    .width(90)
                TableColumn("Detail") { row in
                    cell(row.detail, in: row, isSecondary: true)
                        .help(row.detail)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            TextEditor(text: $comment, selection: $selection)
                .font(.body)
                .frame(height: 100)
                .focused($isCommentFocused)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(isPublishing)

            Text("Signed in to \(OSMServer.host) as \(userName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if isPublishing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Publish") {
                    Task { await runPublish() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .disabled(isPublishing)
        }
        .padding()
        .frame(width: 900)
        .interactiveDismissDisabled(isPublishing)
        .onAppear { isCommentFocused = true }
    }

    /// One table cell. A conflict's row is red.
    private func cell(_ text: String, in row: Row, isSecondary: Bool = false) -> Text {
        Text(text).foregroundStyle(row.isConflict ? AnyShapeStyle(.red) : AnyShapeStyle(isSecondary ? .secondary : .primary))
    }

    private func runPublish() async {
        isPublishing = true
        errorMessage = nil
        do {
            try await publish(comment)
            dismiss()
        } catch OSMAPIClient.APIError.conflicts(let osmIDs) {
            conflicts = Set(osmIDs)
            errorMessage = OSMAPIClient.APIError.conflicts(osmIDs: osmIDs).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isPublishing = false
    }

    // MARK: - Rows

    struct Row: Identifiable {
        let id: String
        let action: String
        let type: String
        let feature: String
        let hole: String
        let osmID: String
        let detail: String
        let isConflict: Bool
    }

    /// Conflicts first, then changed, multipolygon, course outline, new, and deleted. Each group is in hole order.
    private var rows: [Row] {
        let holeOrder = Self.holeOrder(in: course)
        return changes
            .sorted { lhs, rhs in
                let lhsConflict = lhs.osmID.map(conflicts.contains) ?? false
                let rhsConflict = rhs.osmID.map(conflicts.contains) ?? false
                if lhsConflict != rhsConflict { return lhsConflict }
                if lhs.action != rhs.action { return lhs.action < rhs.action }
                let lhsHole = lhs.featureID.flatMap { holeOrder[$0]?.index } ?? .max
                let rhsHole = rhs.featureID.flatMap { holeOrder[$0]?.index } ?? .max
                return lhsHole < rhsHole
            }
            .map { change in
                let isConflict = change.osmID.map(conflicts.contains) ?? false
                return Row(
                    id: change.id,
                    action: Self.actionName(change.action),
                    type: change.action == .courseOutline ? "Outline" : change.type.rawValue.capitalized,
                    feature: change.featureID.map { "#\($0)" } ?? "",
                    hole: change.featureID.flatMap { holeOrder[$0].map { "Hole \($0.number)" } } ?? "",
                    osmID: change.osmID ?? "",
                    detail: isConflict ? "changed in OSM" : Self.detail(for: change, in: course),
                    isConflict: isConflict
                )
            }
    }

    static func actionName(_ action: OSMFeatureChange.Action) -> String {
        switch action {
        case .modify: "Changed"
        case .multipolygon: "Cut out"
        case .courseOutline: "Course outline"
        case .create: "New"
        case .delete: "Deleted"
        }
    }

    /// What the change does, in plain words. The course is used to name the other features a
    /// change involves.
    static func detail(for change: OSMFeatureChange, in course: Course? = nil) -> String {
        if change.action == .multipolygon {
            let names = featureNames(for: change.innerOSMIDs, in: course)
            return "Fairway no longer covers \(names.isEmpty ? "the features inside it" : names)."
        }
        if change.action == .courseOutline {
            return change.osmID?.hasPrefix("n") == true ? "replaces the node" : "takes tags from it"
        }
        var parts: [String] = []
        if change.pointsChanged {
            let names = featureNames(for: change.sharedNodeOSMIDs, in: course)
            parts.append(names.isEmpty ? "points" : "points, edge now follows \(names)")
        }
        if let oldType = change.oldType { parts.append("type, was \(oldType.rawValue)") }
        if change.addsGolfTag { parts.append("adds golf=\(OSMChangeBuilder.tags(for: change.type)["golf"] ?? "")") }
        return parts.joined(separator: ", ")
    }

    /// The course's features with the OSM IDs, as a phrase such as "green #12 and bunkers #14
    /// and #15". Grouped by type. Empty when none of them are in the course.
    static func featureNames(for osmIDs: [String], in course: Course?) -> String {
        guard let course else { return "" }
        let features = course.features.filter { feature in feature.osmID.map(osmIDs.contains) ?? false }
        let groups: [String] = FeatureType.allCases.compactMap { type in
            let ids = features.filter { $0.type == type }.map { "#\($0.id)" }
            guard !ids.isEmpty else { return nil }
            return "\(type.rawValue)\(ids.count == 1 ? "" : "s") \(ids.formatted(.list(type: .and)))"
        }
        return groups.formatted(.list(type: .and))
    }

    /// The hole that uses each feature, with its place in course order.
    static func holeOrder(in course: Course) -> [Int: (index: Int, number: Int)] {
        var order: [Int: (index: Int, number: Int)] = [:]
        for (index, hole) in course.subCourses.flatMap(\.holes).enumerated() {
            for featureID in hole.features + [hole.centerline].compactMap({ $0 }) where order[featureID] == nil {
                order[featureID] = (index, hole.number)
            }
        }
        return order
    }
}

#Preview("Every kind of change") {
    let square = CoordinatePath([
        Coordinate(lat: 40, lon: -105), Coordinate(lat: 40, lon: -104.999),
        Coordinate(lat: 40.001, lon: -104.999), Coordinate(lat: 40.001, lon: -105),
    ])
    let features = [
        Feature(id: 1, type: .fairway, polygon: square, osmID: "r1"),
        Feature(id: 12, type: .green, polygon: square, osmID: "w12"),
        Feature(id: 14, type: .bunker, polygon: square, osmID: "w14"),
        Feature(id: 15, type: .bunker, polygon: square, osmID: "w15"),
        Feature(id: 20, type: .water, polygon: square, osmID: "w20"),
        Feature(id: 30, type: .bunker, polygon: square),
    ]
    let course = Course(
        name: "Preview",
        location: CourseLocation(address: "", city: "", state: "", country: "US", coordinate: Coordinate(lat: 40, lon: -105)),
        features: features,
        subCourses: [SubCourse(name: "Front", holes: [Hole(number: 3, par: 4, features: [1, 12, 14, 15, 20, 30])])]
    )
    PublishToOSMSheet(
        changes: [
            OSMFeatureChange(action: .modify, featureID: 12, type: .green, osmID: "w12", pointsChanged: true),
            OSMFeatureChange(action: .modify, featureID: 1, type: .fairway, osmID: "r1", pointsChanged: true, sharedNodeOSMIDs: ["w14"]),
            OSMFeatureChange(action: .modify, featureID: 20, type: .water, osmID: "w20", oldType: .bunker, pointsChanged: true),
            OSMFeatureChange(action: .modify, featureID: 14, type: .bunker, osmID: "w14", addsGolfTag: true),
            OSMFeatureChange(action: .multipolygon, featureID: 1, type: .fairway, osmID: "r1", innerOSMIDs: ["w12", "w14", "w15"]),
            OSMFeatureChange(action: .create, featureID: 30, type: .bunker, osmID: nil),
            OSMFeatureChange(action: .delete, featureID: nil, type: .tee, osmID: "w40"),
        ],
        course: course,
        userName: "pat"
    ) { _ in }
}

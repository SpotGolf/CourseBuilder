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

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.action)
                            Text(row.type)
                            Text(row.feature)
                            Text(row.hole)
                            Text(row.osmID)
                                .monospaced()
                            Text(row.detail)
                                .foregroundStyle(row.isConflict ? .red : .secondary)
                        }
                        .foregroundStyle(row.isConflict ? .red : .primary)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 160)
            .background(Color(.textBackgroundColor))
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
        .frame(width: 560)
        .interactiveDismissDisabled(isPublishing)
        .onAppear { isCommentFocused = true }
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

    /// Conflicts first, then changed, multipolygon, new, deleted, and skipped. Each group is in hole order.
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
                    type: change.type.rawValue.capitalized,
                    feature: change.featureID.map { "#\($0)" } ?? "",
                    hole: change.featureID.flatMap { holeOrder[$0].map { "Hole \($0.number)" } } ?? "",
                    osmID: change.osmID ?? "",
                    detail: isConflict ? "changed in OSM" : Self.detail(for: change),
                    isConflict: isConflict
                )
            }
    }

    static func actionName(_ action: OSMFeatureChange.Action) -> String {
        switch action {
        case .modify: "Changed"
        case .multipolygon: "Multipolygon"
        case .create: "New"
        case .delete: "Deleted"
        case .skip: "Skipped"
        }
    }

    static func detail(for change: OSMFeatureChange) -> String {
        if let reason = change.reason { return reason }
        if change.action == .multipolygon {
            return "inner: \(change.innerOSMIDs.joined(separator: ", "))"
        }
        var parts: [String] = []
        if change.pointsChanged { parts.append("points") }
        if let oldType = change.oldType { parts.append("type, was \(oldType.rawValue)") }
        return parts.joined(separator: ", ")
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

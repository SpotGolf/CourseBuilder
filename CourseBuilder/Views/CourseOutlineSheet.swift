import SwiftUI

/// Picks the tags a new course outline takes from the misplaced `leisure=golf_course` element.
struct CourseOutlineSheet: View {
    let element: MisplacedCourseElement
    /// Saves the picked tags and whether the old element gets `golf=clubhouse`.
    let save: (_ tags: [String: String], _ tagsOldElementClubhouse: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var movedKeys: Set<String>
    @State private var tagsOldElementClubhouse: Bool
    private let isEditing: Bool

    /// - Parameter outline: The pending outline whose tags are being changed. Nil for a new one.
    init(
        element: MisplacedCourseElement,
        outline: PendingCourseOutline? = nil,
        save: @escaping (_ tags: [String: String], _ tagsOldElementClubhouse: Bool) -> Void
    ) {
        self.element = element
        self.save = save
        isEditing = outline != nil
        let keys = outline.map { Set($0.tags.keys) }
            ?? Set(element.tags.keys.filter { CourseOutline.movesByDefault(key: $0, from: element) })
        _movedKeys = State(initialValue: keys)
        _tagsOldElementClubhouse = State(initialValue: outline?.tagsOldElementClubhouse ?? CourseOutline.clubhouseTagByDefault(for: element))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix Course Outline")
                .font(.headline)

            Text(explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Checked tags go to the new outline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(element.tags.keys.sorted(), id: \.self) { key in
                        Toggle(isOn: binding(for: key)) {
                            Text("\(key)=\(element.tags[key] ?? "")")
                                .monospaced()
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .disabled(CourseOutline.mustMove(key: key, from: element))
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 220)
            .background(Color(.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if CourseOutline.offersClubhouseTag(for: element) {
                Toggle("Tag old element golf=clubhouse", isOn: $tagsOldElementClubhouse)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create Outline") {
                    save(element.tags.filter { movedKeys.contains($0.key) }, CourseOutline.offersClubhouseTag(for: element) && tagsOldElementClubhouse)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
    }

    private var explanation: String {
        if element.isNode {
            "\(element.osmID) is a point tagged leisure=golf_course. OSM asks for this tag on the area of the whole course. Publishing creates an outline with all of its tags and deletes the point."
        } else {
            "\(element.osmID) is tagged leisure=golf_course but is not the area of the whole course. Publishing creates an outline with the checked tags and removes them from \(element.osmID)."
        }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { movedKeys.contains(key) },
            set: { isOn in
                if isOn { movedKeys.insert(key) } else { movedKeys.remove(key) }
            }
        )
    }
}

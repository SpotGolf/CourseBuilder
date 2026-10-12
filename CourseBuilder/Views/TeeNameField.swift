import SwiftUI
import CourseDataSwift

/// Draft text for a tee name that is being edited.
///
/// The draft is independent of the course so the user can clear the field or
/// type through an invalid intermediate value. `commit` applies the draft with
/// `CourseIntegrity.renameTee`; if the rename is rejected (empty or duplicate
/// name) the draft reverts to the tee's current name.
struct TeeNameDraft: Equatable {
    var text: String

    init(name: String) {
        text = name
    }

    /// Applies the draft to the tee at `index`. Returns `false` and reverts the
    /// draft to the current name when the rename is rejected.
    @discardableResult
    mutating func commit(at index: Int, in course: inout Course) -> Bool {
        if CourseIntegrity.renameTee(at: index, to: text, in: &course) {
            return true
        }
        text = course.tees.indices.contains(index) ? course.tees[index].name : ""
        return false
    }
}

/// Edits a tee name with a local draft so the field can be emptied while typing.
/// The rename is applied when the field loses focus or Return is pressed.
struct TeeNameField: View {
    let index: Int
    @Binding var course: Course
    @State private var draft = TeeNameDraft(name: "")
    @FocusState private var isFocused: Bool

    private var currentName: String {
        course.tees.indices.contains(index) ? course.tees[index].name : ""
    }

    var body: some View {
        TextField("Tee Name", text: $draft.text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 150)
            .focused($isFocused)
            .onAppear { draft = TeeNameDraft(name: currentName) }
            .onChange(of: currentName) { _, newValue in
                if !isFocused { draft = TeeNameDraft(name: newValue) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { draft.commit(at: index, in: &course) }
            }
            .onSubmit { draft.commit(at: index, in: &course) }
    }
}

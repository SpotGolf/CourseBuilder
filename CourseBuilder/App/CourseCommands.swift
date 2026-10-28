import SwiftUI

/// Actions for the course list in the main window. `deleteCourse` is nil when no course is selected.
struct CourseListActions {
    var newCourse: () -> Void
    var deleteCourse: (() -> Void)?
}

/// Actions for the selected course. An action is nil when its button is disabled.
struct CourseActions {
    var updateCourseInfo: (() -> Void)?
    var export: (() -> Void)?
    var cleanup: (() -> Void)?
    var importImage: (() -> Void)?
    var openMapEditor: (() -> Void)?
}

extension FocusedValues {
    /// The course list of the main window in front.
    @Entry var courseListActions: CourseListActions?
    /// The selected course of the main window in front.
    @Entry var courseActions: CourseActions?
}

/// Course items in the File, Edit, and View menus, for the main window in front. Items for the
/// selected course are disabled when no course is selected.
struct CourseCommands: Commands {
    @FocusedValue(\.courseListActions) private var listActions
    @FocusedValue(\.courseActions) private var courseActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Course") { listActions?.newCourse() }
                .keyboardShortcut("n")
                .disabled(listActions == nil)
            Button("Delete Course") { listActions?.deleteCourse?() }
                .disabled(listActions?.deleteCourse == nil)
            Divider()
            Button("Export") { courseActions?.export?() }
                .keyboardShortcut("e")
                .disabled(courseActions?.export == nil)
            Button("Cleanup") { courseActions?.cleanup?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(courseActions?.cleanup == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Update Course Info...") { courseActions?.updateCourseInfo?() }
                .disabled(courseActions?.updateCourseInfo == nil)
            Button("Import Image...") { courseActions?.importImage?() }
                .disabled(courseActions?.importImage == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Open Map Editor") { courseActions?.openMapEditor?() }
                .keyboardShortcut("o")
                .disabled(courseActions?.openMapEditor == nil)
            Divider()
        }
    }
}

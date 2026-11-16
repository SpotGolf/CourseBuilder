import SwiftUI
import CourseDataSwift

/// The two views of the selected course.
enum CourseTab: String, CaseIterable, Identifiable {
    case details
    case map

    var id: Self { self }

    var title: String {
        switch self {
        case .details: "Course Details"
        case .map: "Map Editor"
        }
    }
}

extension FocusedValues {
    /// The tab showing for the selected course of the main window in front.
    @Entry var courseTab: Binding<CourseTab>?
}

/// The selected course, with a tab for its details and a tab for its map.
///
/// Both tabs stay alive while the course is selected, so the map keeps its position, selection,
/// and undo history when the user looks at the details and comes back. Only the tab that is
/// showing takes clicks, keys, and menu commands.
struct CourseTabsView: View {
    @Binding var course: Course
    @State private var tab: CourseTab = .details

    var body: some View {
        ZStack {
            ScorecardView(course: $course, isActive: tab == .details)
                .showing(tab == .details)
            if course.subCourses.isEmpty {
                Text("This course has no holes. Add them on the Course Details tab first.")
                    .foregroundStyle(.secondary)
                    .showing(tab == .map)
            } else {
                MapEditorView(course: $course, isActive: tab == .map)
                    .showing(tab == .map)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(CourseTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .focusedSceneValue(\.courseTab, $tab)
    }
}

private extension View {
    /// Shows the view, or keeps it alive out of sight and out of reach.
    func showing(_ isShowing: Bool) -> some View {
        opacity(isShowing ? 1 : 0)
            .allowsHitTesting(isShowing)
            .disabled(!isShowing)
            .accessibilityHidden(!isShowing)
    }
}

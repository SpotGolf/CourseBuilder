import SwiftUI

@main
struct CourseBuilderApp: App {
    @StateObject private var store = CourseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }

        WindowGroup("Map Editor", id: "map-editor", for: UUID.self) { $courseID in
            if let courseID, let course = store.binding(for: courseID) {
                MapEditorView(course: course)
            }
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}

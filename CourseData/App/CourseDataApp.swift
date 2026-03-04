import SwiftUI

@main
struct CourseDataApp: App {
    @StateObject private var store = CourseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }

        WindowGroup("Map Editor", id: "map-editor", for: UUID.self) { $courseID in
            if let courseID, let course = store.courses.first(where: { $0.id == courseID }) {
                MapEditorView(course: course)
                    .environmentObject(store)
            }
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}

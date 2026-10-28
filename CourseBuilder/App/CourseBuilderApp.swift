import SwiftUI

@main
struct CourseBuilderApp: App {
    @StateObject private var store = CourseStore()

    init() {
        // Removes Show Tab Bar and Show All Tabs from the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .commands {
            CourseCommands()
        }

        WindowGroup("Map Editor", id: "map-editor", for: UUID.self) { $courseID in
            if let courseID, let course = store.binding(for: courseID) {
                MapEditorView(course: course, elevationWorker: store.elevationWorker)
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            MapCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

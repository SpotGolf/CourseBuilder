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
        .defaultSize(width: 1400, height: 900)
        .commands {
            CourseCommands()
            MapCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

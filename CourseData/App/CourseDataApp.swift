import SwiftUI

@main
struct CourseDataApp: App {
    @StateObject private var store = CourseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

import SwiftUI

struct SettingsView: View {
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""

    var body: some View {
        Form {
            SecureField("GolfCourseAPI Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .navigationTitle("Settings")
    }
}

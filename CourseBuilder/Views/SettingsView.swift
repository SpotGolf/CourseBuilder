import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""

    var body: some View {
        Form {
            SecureField("GolfCourseAPI Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Section("OpenStreetMap") {
                OSMAccountRow()
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .navigationTitle("Settings")
    }
}

/// Who is signed in to OpenStreetMap, with Sign In or Sign Out.
private struct OSMAccountRow: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var userName: String?
    @State private var isSignedIn = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        LabeledContent("OSM account") {
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                if isSignedIn {
                    Text(userName.map { "Signed in as \($0)" } ?? "Signed in")
                    Button("Sign Out") { signOut() }
                } else {
                    Button("Sign In") { Task { await signIn() } }
                }
            }
            .disabled(isWorking)
        }
        .task { await loadUser() }
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func loadUser() async {
        guard let token = OSMAuth().token else { return }
        isSignedIn = true
        userName = try? await OSMAPIClient(token: token).displayName()
    }

    private func signIn() async {
        isWorking = true
        errorMessage = nil
        do {
            let user = try await OSMAuth().signedInUser { url in
                try await webAuthenticationSession.authenticate(
                    using: url,
                    callback: .customScheme(OSMAuth.callbackScheme),
                    additionalHeaderFields: [:]
                )
            }
            userName = user.displayName
            isSignedIn = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func signOut() {
        OSMAuth().signOut()
        isSignedIn = false
        userName = nil
    }
}

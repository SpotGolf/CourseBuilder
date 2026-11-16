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

            Section("Overpass") {
                OverpassServerRows()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .navigationTitle("Settings")
    }
}

/// Picks the Overpass server that course data is read from, with its API key if it needs one.
private struct OverpassServerRows: View {
    @AppStorage(OverpassSettings.serverKey) private var serverID = OverpassServer.main.id

    var body: some View {
        let server = OverpassServer.server(id: serverID)
        Picker("Server", selection: $serverID) {
            ForEach(OverpassServer.all) { server in
                Text(server.name).tag(server.id)
            }
        }
        if server.needsAPIKey {
            OverpassAPIKeyField(server: server)
                // Each server has its own key.
                .id(server.id)
        }
        Text("CourseBuilder reads a course's OpenStreetMap data from this server. \(server.note)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The API key for one Overpass server.
private struct OverpassAPIKeyField: View {
    @AppStorage private var apiKey: String

    init(server: OverpassServer) {
        _apiKey = AppStorage(wrappedValue: "", OverpassSettings.apiKeyKey(for: server))
    }

    var body: some View {
        SecureField("API Key", text: $apiKey)
            .textFieldStyle(.roundedBorder)
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

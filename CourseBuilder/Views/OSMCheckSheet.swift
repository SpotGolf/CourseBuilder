import SwiftUI

/// Where the check of OSM for existing course data stands.
enum OSMCheckState {
    case checking
    case found(OverpassAPIClient.ParsedResult)
    case notFound
    case failed(String)
}

/// Shows the check of OSM for existing course data, and offers to import what it finds.
struct OSMCheckSheet: View {
    let state: OSMCheckState
    /// What the check is doing, shown while it runs.
    let status: String
    let importData: (OverpassAPIClient.ParsedResult) -> Void
    let close: () -> Void
    /// Stops the check while it runs.
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .checking:
                ProgressView()
                VStack(spacing: 4) {
                    Text("Checking OpenStreetMaps for existing course data")
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
            case .found(let result):
                Text("Course data found. Import it?")
                HStack {
                    Button("Later") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Yes") { importData(result) }
                        .keyboardShortcut(.defaultAction)
                }
            case .notFound:
                Text("No course data found. You'll have to build this one by hand and publish it to OpenStreetMaps.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("OK") { close() }
                    .keyboardShortcut(.defaultAction)
            case .failed(let message):
                Text("Could not check OpenStreetMaps: \(message)")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("OK") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}

import Foundation

/// An Overpass server the app can read OpenStreetMap data from.
///
/// The list comes from the "Public Overpass API instances" table on the OpenStreetMap wiki
/// (https://wiki.openstreetmap.org/wiki/Overpass_API). Servers that cover only another part of
/// the world are left out.
///
/// How each server takes its API key was checked against the server itself on 2026-11-16, by
/// sending a made-up key and reading the error. A server that takes the key in an
/// `Authorization: Bearer` header gets it that way, which keeps the key out of the address.
struct OverpassServer: Identifiable, Hashable {
    /// Saved in the app's settings. Never change one.
    let id: String
    let name: String
    /// What the server costs and covers, shown under the picker.
    let note: String
    /// The address queries are sent to.
    let url: String
    let keyPlacement: KeyPlacement

    /// How a server takes its API key.
    enum KeyPlacement: Hashable {
        /// The server needs no key.
        case none
        /// In an `Authorization: Bearer` header.
        case bearerHeader
        /// As part of the address, where ``OverpassServer/keyPlaceholder`` is. Only for servers
        /// that take the key no other way.
        case path
    }

    static let keyPlaceholder = "YOUR_API_KEY"

    init(id: String, name: String, note: String, url: String, keyPlacement: KeyPlacement = .none) {
        self.id = id
        self.name = name
        self.note = note
        self.url = url
        self.keyPlacement = keyPlacement
    }

    var needsAPIKey: Bool {
        keyPlacement != .none
    }

    /// The address queries are sent to. Nil when the server needs a key and `apiKey` is empty
    /// or cannot be part of an address.
    func interpreterURL(apiKey: String) -> URL? {
        switch keyPlacement {
        case .none:
            return URL(string: url)
        case .bearerHeader:
            return Self.trimmed(apiKey).isEmpty ? nil : URL(string: url)
        case .path:
            let key = Self.trimmed(apiKey)
            guard !key.isEmpty,
                  let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else {
                return nil
            }
            return URL(string: url.replacingOccurrences(of: Self.keyPlaceholder, with: encoded))
        }
    }

    /// The value of the `Authorization` header to send. Nil when the server does not take its
    /// key in a header, or `apiKey` is empty.
    func authorizationHeader(apiKey: String) -> String? {
        let key = Self.trimmed(apiKey)
        guard keyPlacement == .bearerHeader, !key.isEmpty else { return nil }
        return "Bearer \(key)"
    }

    private static func trimmed(_ apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let main = OverpassServer(
        id: "main",
        name: "Overpass API (overpass-api.de)",
        note: "Free, no API key. Shared by everyone and often busy.",
        url: "https://overpass-api.de/api/interpreter"
    )

    static let all: [OverpassServer] = [
        main,
        OverpassServer(
            id: "private-coffee",
            name: "Private.coffee",
            note: "Free, no API key.",
            url: "https://overpass.private.coffee/api/interpreter"
        ),
        OverpassServer(
            id: "dresel-north-america",
            name: "dresel.systems (North America)",
            note: "Free, no API key. Covers North America only.",
            url: "https://ovp.dresel.systems/api-na/interpreter"
        ),
        OverpassServer(
            id: "vk-maps",
            name: "VK Maps",
            note: "Free, no API key.",
            url: "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
        ),
        OverpassServer(
            id: "fairwaymapper",
            name: "FairwayMapper",
            note: "Needs an API key. Free for active OpenStreetMap contributors.",
            url: "https://api.fairwaymapper.com/api/interpreter",
            keyPlacement: .bearerHeader
        ),
        OverpassServer(
            id: "overpass-ch",
            name: "Overpass.ch",
            note: "Needs an API key. Has a free tier.",
            url: "https://api.overpass.ch/v1/interpreter",
            keyPlacement: .bearerHeader
        ),
        OverpassServer(
            id: "nextgis",
            name: "NextGIS",
            note: "Needs an API key. Free.",
            url: "https://overpass.nextgis.com/YOUR_API_KEY/api/interpreter",
            keyPlacement: .path
        ),
        OverpassServer(
            id: "mapsource",
            name: "Mapsource",
            note: "Needs an API key. Free to try, then paid.",
            url: "https://api.mapsource.io/interpreter",
            keyPlacement: .bearerHeader
        ),
        OverpassServer(
            id: "overspan",
            name: "Overspan",
            note: "Needs an API key. Paid.",
            url: "https://api.overspan.dev/api/interpreter",
            keyPlacement: .bearerHeader
        ),
        OverpassServer(
            id: "geofabrik",
            name: "Geofabrik",
            note: "Needs an API key. Paid.",
            url: "https://overpass.geofabrik.de/YOUR_API_KEY/api/interpreter",
            keyPlacement: .path
        ),
        OverpassServer(
            id: "tracestrack",
            name: "Tracestrack",
            note: "Needs an API key. Paid.",
            url: "https://api.tracestrack.com/overpass/YOUR_API_KEY/interpreter",
            keyPlacement: .path
        )
    ]

    /// The server with the ID, or the main server when the ID is unknown.
    static func server(id: String) -> OverpassServer {
        all.first { $0.id == id } ?? main
    }
}

/// The Overpass server and API keys the user picked in Settings.
struct OverpassSettings {
    static let serverKey = "overpassServer"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var server: OverpassServer {
        OverpassServer.server(id: defaults.string(forKey: Self.serverKey) ?? "")
    }

    /// Each server keeps its own key, so switching servers does not lose one.
    static func apiKeyKey(for server: OverpassServer) -> String {
        "overpassAPIKey.\(server.id)"
    }

    func apiKey(for server: OverpassServer) -> String {
        defaults.string(forKey: Self.apiKeyKey(for: server)) ?? ""
    }
}

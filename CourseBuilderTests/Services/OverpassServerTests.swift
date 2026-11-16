import Foundation
import Testing
@testable import CourseBuilder

@Suite("Overpass servers")
struct OverpassServerTests {
    private func makeDefaults() -> UserDefaults {
        let name = "OverpassServerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let keyed = OverpassServer.server(id: "fairwaymapper")

    @Test func serverIDsAreUnique() {
        #expect(Set(OverpassServer.all.map(\.id)).count == OverpassServer.all.count)
    }

    @Test func everyServerHasAnAddress() {
        for server in OverpassServer.all {
            #expect(server.interpreterURL(apiKey: "abc")?.scheme == "https", "\(server.name)")
        }
    }

    @Test func serverWithoutKeyIgnoresTheKey() {
        #expect(!OverpassServer.main.needsAPIKey)
        #expect(OverpassServer.main.interpreterURL(apiKey: "")?.absoluteString == "https://overpass-api.de/api/interpreter")
        #expect(OverpassServer.main.interpreterURL(apiKey: "abc")?.absoluteString == "https://overpass-api.de/api/interpreter")
    }

    @Test func keyGoesInABearerHeader() throws {
        #expect(keyed.needsAPIKey)
        #expect(keyed.interpreterURL(apiKey: "abc123")?.absoluteString == "https://api.fairwaymapper.com/api/interpreter")
        #expect(keyed.authorizationHeader(apiKey: " abc123\n") == "Bearer abc123")

        let request = try OverpassAPIClient.request(for: "out;", server: keyed, apiKey: "abc123")

        #expect(request.url?.absoluteString == "https://api.fairwaymapper.com/api/interpreter")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
    }

    @Test func serversThatTakeABearerHeaderKeepTheKeyOutOfTheAddress() {
        let ids = OverpassServer.all.filter { $0.keyPlacement == .bearerHeader }.map(\.id)
        #expect(ids == ["fairwaymapper", "overpass-ch", "mapsource", "overspan"])
        for server in OverpassServer.all where server.keyPlacement == .bearerHeader {
            #expect(!server.url.contains(OverpassServer.keyPlaceholder), "\(server.name)")
            #expect(server.interpreterURL(apiKey: "secret")?.absoluteString.contains("secret") == false, "\(server.name)")
        }
    }

    @Test func keyGoesIntoTheAddressOnlyWhereThereIsNoHeader() throws {
        let server = OverpassServer.server(id: "geofabrik")

        let request = try OverpassAPIClient.request(for: "out;", server: server, apiKey: " abc123\n")

        #expect(server.keyPlacement == .path)
        #expect(request.url?.absoluteString == "https://overpass.geofabrik.de/abc123/api/interpreter")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func keyInTheAddressCannotChangeTheAddress() {
        let server = OverpassServer.server(id: "geofabrik")
        #expect(server.interpreterURL(apiKey: "a/b?c")?.absoluteString == "https://overpass.geofabrik.de/a%2Fb%3Fc/api/interpreter")
    }

    @Test func keyedServerWithoutKeyHasNoAddress() {
        for server in OverpassServer.all where server.needsAPIKey {
            #expect(server.interpreterURL(apiKey: "") == nil, "\(server.name)")
            #expect(server.interpreterURL(apiKey: "   ") == nil, "\(server.name)")
        }
    }

    @Test func unknownServerIDFallsBackToTheMainServer() {
        #expect(OverpassServer.server(id: "gone") == .main)
        #expect(OverpassSettings(defaults: makeDefaults()).server == .main)
    }

    @Test func settingsKeepOneKeyPerServer() {
        let defaults = makeDefaults()
        let other = OverpassServer.server(id: "overpass-ch")
        defaults.set(keyed.id, forKey: OverpassSettings.serverKey)
        defaults.set("first", forKey: OverpassSettings.apiKeyKey(for: keyed))
        defaults.set("second", forKey: OverpassSettings.apiKeyKey(for: other))

        let settings = OverpassSettings(defaults: defaults)

        #expect(settings.server == keyed)
        #expect(settings.apiKey(for: keyed) == "first")
        #expect(settings.apiKey(for: other) == "second")
        #expect(settings.apiKey(for: .main) == "")
    }

    @Test func requestNamesTheAppAndPostsTheQuery() throws {
        let request = try OverpassAPIClient.request(for: "out;", server: .main, apiKey: "")

        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("out;".utf8))
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("CourseBuilder/") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func requestWithoutNeededKeyFails() {
        #expect(throws: OverpassAPIClient.OverpassError.self) {
            try OverpassAPIClient.request(for: "out;", server: keyed, apiKey: "")
        }
    }
}

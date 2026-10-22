import CryptoKit
import Foundation
import Security

/// Signs in to OpenStreetMap with OAuth 2.0 and PKCE, and keeps the token in the Keychain.
struct OSMAuth {
    enum AuthError: LocalizedError {
        case missingCode
        case stateMismatch
        case tokenRequestFailed(statusCode: Int)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .missingCode: "OpenStreetMap did not return a sign-in code."
            case .stateMismatch: "The OpenStreetMap sign-in answer did not match the request."
            case .tokenRequestFailed(let code): "OpenStreetMap sign-in failed with HTTP \(code)."
            case .keychain(let status): "Could not save the OpenStreetMap sign-in to the Keychain (\(status))."
            }
        }
    }

    static let callbackScheme = "coursebuilder"
    static let redirectURI = "coursebuilder://oauth/callback"
    static let scopes = "read_prefs write_api"
    private static let keychainService = "golf.spot.CourseBuilder.osm"
    private static let keychainAccount = "openstreetmap.org"

    var session: URLSession = .shared

    /// The saved token, or nil when signed out.
    var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Signs in and saves the token.
    ///
    /// - Parameter authenticate: Shows the sign-in page at the given URL and returns the
    ///   callback URL, such as SwiftUI's `WebAuthenticationSession.authenticate`.
    @discardableResult
    func signIn(authenticate: (URL) async throws -> URL) async throws -> String {
        let verifier = Self.makeVerifier()
        let state = UUID().uuidString
        let callback = try await authenticate(Self.authorizeURL(challenge: Self.challenge(for: verifier), state: state))

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw AuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.missingCode }

        let token = try await requestToken(code: code, verifier: verifier)
        try save(token)
        return token
    }

    func signOut() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func authorizeURL(challenge: String, state: String) -> URL {
        var components = URLComponents(url: OSMServer.webURL.appendingPathComponent("oauth2/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: OSMServer.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// A random PKCE code verifier.
    static func makeVerifier() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// The PKCE S256 code challenge for a verifier.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func requestToken(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: OSMServer.webURL.appendingPathComponent("oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "client_id", value: OSMServer.clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw AuthError.tokenRequestFailed(statusCode: statusCode)
        }
        return token
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
    }

    private func save(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychain(status) }
    }
}

extension OSMAuth {
    /// The token and display name of the signed-in user, signing in first when needed. A token
    /// OSM rejects is dropped and the user signs in again.
    func signedInUser(authenticate: (URL) async throws -> URL) async throws -> (token: String, displayName: String) {
        if let token {
            do {
                let name = try await OSMAPIClient(token: token, session: session).displayName()
                return (token, name)
            } catch OSMAPIClient.APIError.http(statusCode: 401, _) {
                signOut()
            }
        }
        let token = try await signIn(authenticate: authenticate)
        let name = try await OSMAPIClient(token: token, session: session).displayName()
        return (token, name)
    }

    /// Runs `operation` with the token. When OSM rejects the token, it is dropped, the user signs
    /// in again, and `operation` runs once more with the new token.
    func retryingAfterSignIn<T>(
        token: String,
        authenticate: (URL) async throws -> URL,
        _ operation: (String) async throws -> T
    ) async throws -> T {
        try await Self.retryingAfterSignIn(
            token: token,
            signIn: {
                signOut()
                return try await signIn(authenticate: authenticate)
            },
            operation
        )
    }

    /// Runs `operation` with the token, and once more with the token from `signIn` when OSM
    /// answers 401.
    static func retryingAfterSignIn<T>(
        token: String,
        signIn: () async throws -> String,
        _ operation: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(token)
        } catch OSMAPIClient.APIError.http(statusCode: 401, _) {
            return try await operation(try await signIn())
        }
    }
}

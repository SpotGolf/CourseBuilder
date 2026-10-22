import Testing
@testable import CourseBuilder

@Suite("OSM auth")
struct OSMAuthTests {
    @Test func retriesWithNewTokenAfter401() async throws {
        var tokens: [String] = []
        var signIns = 0

        let result = try await OSMAuth.retryingAfterSignIn(token: "old", signIn: {
            signIns += 1
            return "new"
        }) { token in
            tokens.append(token)
            if token == "old" { throw OSMAPIClient.APIError.http(statusCode: 401, message: "") }
            return "published"
        }

        #expect(result == "published")
        #expect(tokens == ["old", "new"])
        #expect(signIns == 1)
    }

    @Test func otherErrorsDoNotSignIn() async {
        var signIns = 0

        await #expect(throws: OSMAPIClient.APIError.http(statusCode: 500, message: "")) {
            try await OSMAuth.retryingAfterSignIn(token: "old", signIn: {
                signIns += 1
                return "new"
            }) { _ in
                throw OSMAPIClient.APIError.http(statusCode: 500, message: "")
            }
        }
        #expect(signIns == 0)
    }

    @Test func secondRejectionIsThrown() async {
        await #expect(throws: OSMAPIClient.APIError.http(statusCode: 401, message: "")) {
            try await OSMAuth.retryingAfterSignIn(token: "old", signIn: { "new" }) { _ in
                throw OSMAPIClient.APIError.http(statusCode: 401, message: "")
            }
        }
    }
}

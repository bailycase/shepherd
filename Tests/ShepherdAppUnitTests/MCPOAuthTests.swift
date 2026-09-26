import Foundation
import Testing
@testable import ShepherdApp

/// The parts of OAuth that are pure: challenges, where metadata lives, PKCE, scopes, refresh
/// timing and the authorize URL.
@Suite("MCP OAuth")
struct MCPOAuthTests {
    @Test(arguments: [
        (#"Bearer resource_metadata="https://mcp.notion.com/.well-known/oauth-protected-resource/mcp""#,
         "Bearer", ["resource_metadata": "https://mcp.notion.com/.well-known/oauth-protected-resource/mcp"]),
        (#"Bearer realm="linear", error="insufficient_scope", scope="issues:write read", error_description="Need \"write\"""#,
         "Bearer", ["realm": "linear", "error": "insufficient_scope", "scope": "issues:write read", "error_description": #"Need "write""#]),
        (#"Bearer error=invalid_token,scope=read"#, "Bearer", ["error": "invalid_token", "scope": "read"]),
        ("bearer", "bearer", [:]),
    ] as [(String, String, [String: String])])
    func wwwAuthenticateParses(header: String, scheme: String, params: [String: String]) throws {
        let challenge = try #require(MCPAuthChallenge.bearer(in: header))
        #expect(challenge.scheme == scheme)
        #expect(challenge.params == params)
    }

    @Test func theBearerChallengeIsPickedFromSeveral() throws {
        let challenge = try #require(MCPAuthChallenge.bearer(in: #"Basic realm="x", Bearer scope="a b", resource_metadata="https://r/m""#))
        #expect(challenge.scopes == ["a", "b"])
        #expect(challenge.resourceMetadata == URL(string: "https://r/m"))
    }

    @Test(arguments: [
        // The challenge's metadata first, then the path's well-known, then the root's.
        ("https://mcp.notion.com/mcp", #"Bearer resource_metadata="https://meta.notion.com/prm""#,
         ["https://meta.notion.com/prm", "https://mcp.notion.com/.well-known/oauth-protected-resource/mcp",
          "https://mcp.notion.com/.well-known/oauth-protected-resource"]),
        ("https://api.githubcopilot.com/mcp/", nil,
         ["https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp",
          "https://api.githubcopilot.com/.well-known/oauth-protected-resource"]),
        ("http://127.0.0.1:8123", nil, ["http://127.0.0.1:8123/.well-known/oauth-protected-resource"]),
    ] as [(String, String?, [String])])
    func protectedResourceMetadataIsTriedInOrder(server: String, header: String?, expected: [String]) throws {
        let urls = MCPOAuthService.protectedResourceMetadataURLs(server: try #require(URL(string: server)),
                                                                 challenge: MCPAuthChallenge.bearer(in: header))
        #expect(urls.map(\.absoluteString) == expected)
    }

    @Test(arguments: [
        ("https://auth.example.com", ["https://auth.example.com/.well-known/oauth-authorization-server",
                                      "https://auth.example.com/.well-known/openid-configuration"]),
        ("https://auth.example.com/tenant1", ["https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
                                              "https://auth.example.com/.well-known/openid-configuration/tenant1",
                                              "https://auth.example.com/tenant1/.well-known/openid-configuration"]),
    ])
    func authorizationServerMetadataIsTriedInOrder(issuer: String, expected: [String]) throws {
        #expect(MCPOAuthService.authorizationServerMetadataURLs(issuer: try #require(URL(string: issuer))).map(\.absoluteString)
            == expected)
    }

    /// RFC 7636, appendix B.
    @Test func pkceMatchesTheRFCVector() {
        #expect(MCPPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifiersAndStatesAreLongAndURLSafe() {
        let a = MCPPKCE.verifier(), b = MCPPKCE.randomString()
        #expect(a.count == 43 && b.count == 43)
        #expect(a != b)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func signingInAgainAsksForTheCurrentScopesPlusTheMissingOnes() {
        #expect(MCPScopes.union(["read", "write"], ["issues:write", "read"]) == ["read", "write", "issues:write"])
    }

    @Test func configuredScopesWinThenTheChallengesThenTheResources() {
        let metadata = MCPAuthorizationServerMetadata(issuer: "i", authorizationEndpoint: "https://a/authorize", tokenEndpoint: "https://a/token")
        var discovery = MCPOAuthDiscovery(resourceMetadata: MCPProtectedResourceMetadata(scopesSupported: ["r"]), issuer: "i",
                                          metadata: metadata, resource: "https://x/mcp", challengeScopes: ["c"])
        #expect(discovery.scopes(configured: ["mine"]) == ["mine"])
        #expect(discovery.scopes(configured: []) == ["c"])
        discovery.challengeScopes = []
        #expect(discovery.scopes(configured: []) == ["r"])
    }

    @Test(arguments: [
        ("HTTPS://MCP.Notion.com/mcp#frag", "https://mcp.notion.com/mcp"),
        ("https://mcp.linear.app/", "https://mcp.linear.app"),
        ("https://api.githubcopilot.com:443/mcp/", "https://api.githubcopilot.com/mcp/"),
    ])
    func theResourceIsTheCanonicalServerURL(url: String, expected: String) throws {
        #expect(MCPOAuthService.canonicalResource(try #require(URL(string: url))) == expected)
    }

    @Test func aServerWithoutS256IsRefused() {
        let plain = MCPAuthorizationServerMetadata(issuer: nil, authorizationEndpoint: "a", tokenEndpoint: "t",
                                                   codeChallengeMethodsSupported: ["plain"])
        let unlisted = MCPAuthorizationServerMetadata(issuer: nil, authorizationEndpoint: "a", tokenEndpoint: "t")
        #expect(!plain.supportsS256)
        #expect(unlisted.supportsS256)
    }

    @Test func theAuthorizeURLCarriesPKCEStateAndResource() throws {
        let metadata = MCPAuthorizationServerMetadata(issuer: "https://auth.x", authorizationEndpoint: "https://auth.x/authorize?prompt=consent",
                                                      tokenEndpoint: "https://auth.x/token")
        let discovery = MCPOAuthDiscovery(issuer: "https://auth.x", metadata: metadata, resource: "https://mcp.x/mcp", challengeScopes: [])
        let client = MCPOAuthClient(clientID: "c+1", redirectURI: "http://127.0.0.1:5000/callback", registeredDynamically: true)
        let url = try #require(MCPOAuthService.authorizationURL(discovery, client: client, scopes: ["read", "issues:write"],
                                                                state: "s", challenge: "ch"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(items == ["prompt": "consent", "response_type": "code", "client_id": "c+1",
                          "redirect_uri": "http://127.0.0.1:5000/callback", "code_challenge": "ch",
                          "code_challenge_method": "S256", "state": "s", "resource": "https://mcp.x/mcp", "scope": "read issues:write"])
        #expect(url.absoluteString.contains("client_id=c%2B1"))
    }

    /// Refreshed when fewer than five minutes remain; a token with no expiry never is.
    @Test(arguments: [
        (Int64?(1_000_000 + 5 * 60 * 1000 + 1), false),
        (Int64?(1_000_000 + 5 * 60 * 1000 - 1), true),
        (Int64?(999_000), true),
        (nil, false),
    ] as [(Int64?, Bool)])
    func refreshTiming(expiresAtMs: Int64?, refresh: Bool) {
        let token = MCPOAuthToken(issuer: "i", tokenEndpoint: "t", clientID: "c", redirectURI: "r", resource: "x", accessToken: "a",
                                  expiresAtMs: expiresAtMs, scopes: [], refreshedAtMs: 0)
        #expect(token.needsRefresh(nowMs: 1_000_000) == refresh)
    }

    @Test func theAccountComesFromTheIDTokensEmailOrUsername() {
        func token(_ payload: String) -> String {
            "h." + Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        }
        #expect(MCPOAuthService.account(fromIDToken: token(#"{"email":"baily@acme.dev","preferred_username":"b"}"#)) == "baily@acme.dev")
        #expect(MCPOAuthService.account(fromIDToken: token(#"{"preferred_username":"baily"}"#)) == "baily")
        #expect(MCPOAuthService.account(fromIDToken: "not-a-jwt") == nil)
    }

    @Test(arguments: [
        ("notion", "mcp.notion.com", "Notion", "notion.com"),
        ("sentry", "auth.sentry.io", "Sentry", "sentry.io"),
        ("local", "127.0.0.1", "Local", "127.0.0.1"),
    ])
    func theSheetNamesTheProviderByItsDomain(server: String, host: String, provider: String, domain: String) {
        #expect(MCPSignInFlow.providerName(server: server, host: host) == provider)
        #expect(MCPSignInFlow.domain(host) == domain)
    }
}

/// Sign-in goes only over https, or plain http to this Mac.
@Suite("MCP OAuth transport")
struct MCPOAuthTransportTests {
    @Test(arguments: [
        ("https://auth.example.com/authorize", true), ("http://127.0.0.1:8123/token", true), ("http://localhost/token", true),
        ("http://auth.example.com/token", false), ("file:///etc/passwd", false), ("javascript:alert(1)", false),
        ("shepherd://x", false),
    ])
    func onlyHTTPSOrThisMacIsTrusted(url: String, trusted: Bool) throws {
        #expect(MCPOAuthService.isTrusted(try #require(URL(string: url))) == trusted)
    }

    /// An authorization server whose endpoints are plain http elsewhere is refused before
    /// anything is registered or opened.
    @Test func discoveryRefusesPlainHTTPEndpoints() async throws {
        let http = MetadataStub([
            "https://mcp.example.com/.well-known/oauth-protected-resource/mcp":
                #"{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com"]}"#,
            "https://auth.example.com/.well-known/oauth-authorization-server":
                #"{"issuer":"https://auth.example.com","authorization_endpoint":"http://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","code_challenge_methods_supported":["S256"]}"#,
        ])
        await #expect(throws: MCPOAuthError.insecure("auth.example.com")) {
            try await MCPOAuthService(http: http).discover(server: try #require(URL(string: "https://mcp.example.com/mcp")), challenge: nil)
        }
    }

    @Test func aPlainHTTPServerOffThisMacIsNeverSignedIn() async throws {
        await #expect(throws: MCPOAuthError.insecure("mcp.example.com")) {
            try await MCPOAuthService(http: MetadataStub([:])).discover(server: try #require(URL(string: "http://mcp.example.com/mcp")),
                                                                       challenge: nil)
        }
    }

    @Test func theAuthorizeLinkIsNeverBuiltForAnUntrustedEndpoint() {
        let metadata = MCPAuthorizationServerMetadata(issuer: "x", authorizationEndpoint: "http://auth.example.com/authorize",
                                                      tokenEndpoint: "https://auth.example.com/token")
        let discovery = MCPOAuthDiscovery(issuer: "x", metadata: metadata, resource: "https://mcp.example.com", challengeScopes: [])
        let client = MCPOAuthClient(clientID: "c", redirectURI: "http://127.0.0.1:1/callback", registeredDynamically: true)
        #expect(MCPOAuthService.authorizationURL(discovery, client: client, scopes: [], state: "s", challenge: "c") == nil)
    }
}

/// Answers GETs from a table; everything else is 404.
private struct MetadataStub: MCPHTTP {
    let bodies: [String: String]

    init(_ bodies: [String: String]) {
        self.bodies = bodies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body = bodies[url.absoluteString]
        return (Data((body ?? "").utf8), HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: [:])!)
    }
}

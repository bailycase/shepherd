import CryptoKit
import Foundation
import ShepherdProtocol

// OAuth 2.1 for remote MCP servers, per the MCP authorization spec, done by the app:
// protected-resource metadata (RFC 9728) → authorization-server metadata (RFC 8414 / OIDC) →
// Dynamic Client Registration (RFC 7591) → PKCE S256 in the system browser with a loopback
// redirect → token exchange → refresh. Client ID Metadata Documents need a public https URL
// Shepherd doesn't have, so they are skipped.

/// HTTP as OAuth needs it; tests hand in a session pointed at a fake server on 127.0.0.1.
protocol MCPHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The response's head only, for a stream that never ends (a legacy SSE endpoint).
    func headers(_ request: URLRequest) async throws -> HTTPURLResponse
}

extension MCPHTTP {
    func headers(_ request: URLRequest) async throws -> HTTPURLResponse {
        try await send(request).1
    }
}

struct URLSessionHTTP: MCPHTTP {
    var session: URLSession = URLSession(configuration: .ephemeral)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPOAuthError.badResponse("not HTTP") }
        return (data, http)
    }

    func headers(_ request: URLRequest) async throws -> HTTPURLResponse {
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw MCPOAuthError.badResponse("not HTTP") }
        return http
    }
}

/// One challenge of a `WWW-Authenticate` header: its scheme and parameters (keys lowercased).
struct MCPAuthChallenge: Equatable, Sendable {
    var scheme: String
    var params: [String: String]

    var resourceMetadata: URL? { params["resource_metadata"].flatMap(URL.init(string:)) }
    var scopes: [String] { params["scope"].map { $0.split(separator: " ").map(String.init) } ?? [] }
    var error: String? { params["error"] }

    /// Parses `Bearer realm="x", error="insufficient_scope", scope="a b", resource_metadata="…"`,
    /// with several challenges when the header carries them.
    static func parse(_ header: String) -> [MCPAuthChallenge] {
        var challenges: [MCPAuthChallenge] = []
        var scanner = Substring(header)
        func skipSpaceAndCommas() {
            while let c = scanner.first, c == " " || c == "," || c == "\t" { scanner.removeFirst() }
        }
        func token() -> String {
            let end = scanner.firstIndex { " ,=\t\"".contains($0) } ?? scanner.endIndex
            defer { scanner = scanner[end...] }
            return String(scanner[..<end])
        }
        while true {
            skipSpaceAndCommas()
            guard !scanner.isEmpty else { break }
            let first = token()
            guard !first.isEmpty else { scanner.removeFirst(); continue }
            if scanner.first == "=" {
                // A parameter with no scheme before it belongs to the last challenge.
                scanner.removeFirst()
                let value = paramValue(&scanner)
                if challenges.isEmpty { challenges.append(MCPAuthChallenge(scheme: "", params: [:])) }
                challenges[challenges.count - 1].params[first.lowercased()] = value
                continue
            }
            var challenge = MCPAuthChallenge(scheme: first, params: [:])
            while true {
                skipSpaceAndCommas()
                let save = scanner
                let key = token()
                guard !key.isEmpty, scanner.first == "=" else {
                    scanner = save
                    break
                }
                scanner.removeFirst()
                // token68 (`Basic abc==`) has trailing `=`s; treat it as the challenge's value.
                challenge.params[key.lowercased()] = paramValue(&scanner)
            }
            challenges.append(challenge)
        }
        return challenges
    }

    private static func paramValue(_ scanner: inout Substring) -> String {
        while scanner.first == " " { scanner.removeFirst() }
        if scanner.first == "\"" {
            scanner.removeFirst()
            var value = ""
            while let c = scanner.first {
                scanner.removeFirst()
                if c == "\\", let next = scanner.first {
                    value.append(next)
                    scanner.removeFirst()
                } else if c == "\"" {
                    break
                } else {
                    value.append(c)
                }
            }
            return value
        }
        let end = scanner.firstIndex { $0 == "," || $0 == " " } ?? scanner.endIndex
        defer { scanner = scanner[end...] }
        return String(scanner[..<end])
    }

    /// The Bearer challenge, or the first one.
    static func bearer(in header: String?) -> MCPAuthChallenge? {
        guard let header else { return nil }
        let all = parse(header)
        return all.first { $0.scheme.caseInsensitiveCompare("Bearer") == .orderedSame } ?? all.first
    }
}

/// RFC 9728.
struct MCPProtectedResourceMetadata: Codable, Equatable, Sendable {
    var resource: String?
    var authorizationServers: [String]?
    var scopesSupported: [String]?
    var resourceName: String?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case resourceName = "resource_name"
    }
}

/// RFC 8414 / OpenID Connect discovery.
struct MCPAuthorizationServerMetadata: Codable, Equatable, Sendable {
    var issuer: String?
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var registrationEndpoint: String?
    var codeChallengeMethodsSupported: [String]?
    var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case scopesSupported = "scopes_supported"
    }

    /// Refused when the server lists its PKCE methods and S256 isn't one.
    var supportsS256: Bool {
        codeChallengeMethodsSupported.map { $0.contains("S256") } ?? true
    }
}

/// What the Keychain holds for a signed-in server (`oauth/<server>`).
struct MCPOAuthToken: Codable, Equatable, Sendable {
    var issuer: String
    var tokenEndpoint: String
    var clientID: String
    var clientSecret: String?
    var redirectURI: String
    var resource: String
    var accessToken: String
    var refreshToken: String?
    var expiresAtMs: Int64?
    var scopes: [String]
    var account: String?
    var refreshedAtMs: Int64

    /// Refresh when fewer than 5 minutes remain.
    static let refreshMargin: Int64 = 5 * 60 * 1000

    func needsRefresh(nowMs: Int64) -> Bool {
        guard let expiresAtMs else { return false }
        return expiresAtMs - nowMs < Self.refreshMargin
    }

    func isExpired(nowMs: Int64) -> Bool {
        guard let expiresAtMs else { return false }
        return expiresAtMs <= nowMs
    }
}

enum MCPOAuthError: Error, Equatable, CustomStringConvertible {
    case noMetadata(String)
    case noS256
    case noRegistration(provider: String)
    case registrationFailed(String)
    case denied(error: String, description: String?)
    case tokenFailed(error: String, description: String?)
    /// `invalid_grant` on refresh: the sign-in is over.
    case expired
    case badResponse(String)
    case timedOut
    case cancelled

    var description: String {
        switch self {
        case .noMetadata(let host): "\(host) didn’t say where to sign in."
        case .noS256: "The sign-in server doesn’t support PKCE (S256), so Shepherd won’t use it."
        case .noRegistration(let provider): "\(provider) doesn’t allow registration: add a client ID under Advanced."
        case .registrationFailed(let reason): "Registering Shepherd failed: \(reason)"
        case .denied(let error, let description): description.map { "\(error): \($0)" } ?? error
        case .tokenFailed(let error, let description): description.map { "\(error): \($0)" } ?? error
        case .expired: "The sign-in expired."
        case .badResponse(let reason): reason
        case .timedOut: "Nobody finished signing in within 10 minutes."
        case .cancelled: "Cancelled."
        }
    }
}

/// PKCE (RFC 7636) and the random `state`.
enum MCPPKCE {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomString(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func verifier() -> String { randomString(bytes: 32) }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// Where the sign-in server was found, and what to ask it for.
struct MCPOAuthDiscovery: Equatable, Sendable {
    var resourceMetadata: MCPProtectedResourceMetadata?
    /// Where the resource metadata came from (the MCP server's host, usually).
    var resourceMetadataURL: URL?
    var issuer: String
    var metadata: MCPAuthorizationServerMetadata
    /// The canonical server URL, sent as `resource` on authorize and token.
    var resource: String
    var challengeScopes: [String]

    /// `oauth.scopes` if set, else the challenge's, else what the resource says it supports.
    func scopes(configured: [String]) -> [String] {
        if !configured.isEmpty { return configured }
        if !challengeScopes.isEmpty { return challengeScopes }
        return resourceMetadata?.scopesSupported ?? []
    }
}

/// The registered client: from Dynamic Client Registration or `oauth.clientId`.
struct MCPOAuthClient: Equatable, Sendable {
    var clientID: String
    var clientSecret: String?
    var authMethod: String?
    var redirectURI: String
    /// "Dynamic client registration" or "Client ID from Advanced".
    var registeredDynamically: Bool
}

/// The network half of OAuth. Every call takes what it needs; nothing is stored here.
struct MCPOAuthService: Sendable {
    let http: MCPHTTP

    // MARK: Discovery

    /// RFC 9728's well-known URLs for a server: `<origin>/.well-known/oauth-protected-resource<path>`,
    /// then the root one. The challenge's `resource_metadata` goes first when it has one.
    static func protectedResourceMetadataURLs(server: URL, challenge: MCPAuthChallenge?) -> [URL] {
        var urls: [URL] = []
        if let url = challenge?.resourceMetadata { urls.append(url) }
        guard let origin = origin(of: server) else { return urls }
        let path = trimmedPath(server)
        if !path.isEmpty, let url = URL(string: origin + "/.well-known/oauth-protected-resource" + path) { urls.append(url) }
        if let url = URL(string: origin + "/.well-known/oauth-protected-resource") { urls.append(url) }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// RFC 8414 and OIDC for an issuer. With a path: oauth-authorization-server<path>,
    /// openid-configuration<path>, then <issuer>/.well-known/openid-configuration. Without one:
    /// oauth-authorization-server, then openid-configuration.
    static func authorizationServerMetadataURLs(issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        let path = trimmedPath(issuer)
        let strings: [String]
        if path.isEmpty {
            strings = [origin + "/.well-known/oauth-authorization-server", origin + "/.well-known/openid-configuration"]
        } else {
            strings = [origin + "/.well-known/oauth-authorization-server" + path,
                       origin + "/.well-known/openid-configuration" + path,
                       origin + path + "/.well-known/openid-configuration"]
        }
        return strings.compactMap(URL.init(string:))
    }

    /// The server URL as the `resource` parameter: lowercased scheme and host, no fragment, and
    /// no lone trailing slash.
    static func canonicalResource(_ server: URL) -> String {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return server.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string ?? server.absoluteString
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(bracketed)\(port)"
    }

    private static func trimmedPath(_ url: URL) -> String {
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func discover(server: URL, challenge: MCPAuthChallenge?) async throws -> MCPOAuthDiscovery {
        var prm: MCPProtectedResourceMetadata?
        var prmURL: URL?
        for url in Self.protectedResourceMetadataURLs(server: server, challenge: challenge) {
            if let found: MCPProtectedResourceMetadata = try? await getJSON(url) {
                prm = found
                prmURL = url
                break
            }
        }
        let issuer: String
        if let first = prm?.authorizationServers?.first {
            issuer = first
        } else {
            // 2025-03-26: the server's origin is its own authorization server.
            issuer = Self.origin(of: server) ?? server.absoluteString
        }
        guard let issuerURL = URL(string: issuer) else { throw MCPOAuthError.noMetadata(server.host ?? issuer) }
        var metadata: MCPAuthorizationServerMetadata?
        for url in Self.authorizationServerMetadataURLs(issuer: issuerURL) {
            if let found: MCPAuthorizationServerMetadata = try? await getJSON(url) {
                metadata = found
                break
            }
        }
        if metadata == nil, prm == nil, let origin = Self.origin(of: server) {
            metadata = MCPAuthorizationServerMetadata(issuer: origin, authorizationEndpoint: origin + "/authorize",
                                                      tokenEndpoint: origin + "/token", registrationEndpoint: origin + "/register")
        }
        guard let metadata else { throw MCPOAuthError.noMetadata(issuerURL.host ?? issuer) }
        guard metadata.supportsS256 else { throw MCPOAuthError.noS256 }
        let resource = prm?.resource.flatMap { $0.isEmpty ? nil : $0 } ?? Self.canonicalResource(server)
        return MCPOAuthDiscovery(resourceMetadata: prm, resourceMetadataURL: prmURL, issuer: metadata.issuer ?? issuer,
                                 metadata: metadata, resource: resource, challengeScopes: challenge?.scopes ?? [])
    }

    // MARK: Registration

    /// RFC 7591 for a public client on the loopback redirect.
    func register(_ metadata: MCPAuthorizationServerMetadata, redirectURI: String, provider: String) async throws -> MCPOAuthClient {
        guard let endpoint = metadata.registrationEndpoint.flatMap(URL.init(string:)) else {
            throw MCPOAuthError.noRegistration(provider: provider)
        }
        let body: [String: Any] = [
            "client_name": "Shepherd",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MCPOAuthError.registrationFailed(Self.oauthError(data)?.description ?? "HTTP \(response.statusCode)")
        }
        struct Registered: Decodable {
            var client_id: String
            var client_secret: String?
            var token_endpoint_auth_method: String?
        }
        guard let registered = try? JSONDecoder().decode(Registered.self, from: data) else {
            throw MCPOAuthError.registrationFailed("no client_id in the answer")
        }
        return MCPOAuthClient(clientID: registered.client_id, clientSecret: registered.client_secret,
                              authMethod: registered.token_endpoint_auth_method, redirectURI: redirectURI,
                              registeredDynamically: true)
    }

    // MARK: Authorization

    static func authorizationURL(_ discovery: MCPOAuthDiscovery, client: MCPOAuthClient, scopes: [String],
                                 state: String, challenge: String) -> URL? {
        guard var components = URLComponents(string: discovery.metadata.authorizationEndpoint) else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: client.redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: discovery.resource),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        components.queryItems = items
        // `+` in a query reads as a space to many servers.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    func exchange(code: String, verifier: String, discovery: MCPOAuthDiscovery, client: MCPOAuthClient,
                  requestedScopes: [String], nowMs: Int64) async throws -> MCPOAuthToken {
        let form = [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", client.redirectURI),
            ("client_id", client.clientID), ("code_verifier", verifier), ("resource", discovery.resource),
        ]
        let answer = try await tokenRequest(endpoint: discovery.metadata.tokenEndpoint, form: form,
                                            clientID: client.clientID, clientSecret: client.clientSecret, authMethod: client.authMethod)
        return MCPOAuthToken(
            issuer: discovery.issuer, tokenEndpoint: discovery.metadata.tokenEndpoint, clientID: client.clientID,
            clientSecret: client.clientSecret, redirectURI: client.redirectURI, resource: discovery.resource,
            accessToken: answer.accessToken, refreshToken: answer.refreshToken,
            expiresAtMs: answer.expiresIn.map { nowMs + Int64($0 * 1000) },
            scopes: answer.scope?.split(separator: " ").map(String.init) ?? requestedScopes,
            account: answer.idToken.flatMap(Self.account(fromIDToken:)), refreshedAtMs: nowMs)
    }

    /// Refreshes a token; `invalid_grant` (or no refresh token) means the sign-in expired.
    func refresh(_ token: MCPOAuthToken, nowMs: Int64) async throws -> MCPOAuthToken {
        guard let refreshToken = token.refreshToken else { throw MCPOAuthError.expired }
        let form = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", token.clientID),
                    ("resource", token.resource)]
        let answer: TokenAnswer
        do {
            answer = try await tokenRequest(endpoint: token.tokenEndpoint, form: form, clientID: token.clientID,
                                            clientSecret: token.clientSecret, authMethod: nil)
        } catch MCPOAuthError.tokenFailed(let error, _) where error == "invalid_grant" {
            throw MCPOAuthError.expired
        }
        var next = token
        next.accessToken = answer.accessToken
        next.refreshToken = answer.refreshToken ?? refreshToken
        next.expiresAtMs = answer.expiresIn.map { nowMs + Int64($0 * 1000) }
        if let scope = answer.scope { next.scopes = scope.split(separator: " ").map(String.init) }
        next.refreshedAtMs = nowMs
        return next
    }

    struct TokenAnswer: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?
        var scope: String?
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case idToken = "id_token"
        }
    }

    private func tokenRequest(endpoint: String, form: [(String, String)], clientID: String, clientSecret: String?,
                              authMethod: String?) async throws -> TokenAnswer {
        guard let url = URL(string: endpoint) else { throw MCPOAuthError.badResponse("bad token endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = form
        if let clientSecret {
            if authMethod == "client_secret_basic" {
                let pair = "\(Self.formEncode(clientID)):\(Self.formEncode(clientSecret))"
                request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            } else {
                fields.append(("client_secret", clientSecret))
            }
        }
        request.httpBody = Data(fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&").utf8)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let error = Self.oauthError(data) { throw error }
            throw MCPOAuthError.tokenFailed(error: "HTTP \(response.statusCode)", description: nil)
        }
        guard let answer = try? JSONDecoder().decode(TokenAnswer.self, from: data) else {
            throw MCPOAuthError.badResponse("The token answer had no access_token.")
        }
        return answer
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func oauthError(_ data: Data) -> MCPOAuthError? {
        struct Body: Decodable {
            var error: String
            var error_description: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return .tokenFailed(error: body.error, description: body.error_description)
    }

    /// `email` or `preferred_username` from an id_token's payload: display only, never verified.
    static func account(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["email"] as? String) ?? (object["preferred_username"] as? String)
    }

    private func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw MCPOAuthError.badResponse("HTTP \(response.statusCode)") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum MCPScopes {
    /// What to ask for when signing in again after a 403: the current scopes plus the missing ones, in order.
    static func union(_ current: [String], _ missing: [String]) -> [String] {
        var seen = Set<String>()
        return (current + missing).filter { seen.insert($0).inserted }
    }
}

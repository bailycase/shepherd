import Foundation
import ShepherdRemote

/// Talks to the push relay at `https://api.useshepherd.app/api/push/registrations`.
/// Stateless: each call is one HTTP request. Errors are thrown, never swallowed.
///
/// Relay contract:
/// - POST   → 201 + Registration JSON      (new registration)
/// - PATCH  → 2xx                           (renewed / token updated)
/// - PATCH  → 401                           (expired or invalidated — caller should re-register)
/// - DELETE → 204                           (revoked, already deleted, or expired — gone either way)
/// - DELETE → 401                           (wrong credential for a **still-active** registration)
///
/// The relay returns camelCase JSON (`sendToken`, `manageToken`) — no custom CodingKeys.
/// All requests use an ephemeral session that rejects redirects (the manage token is a
/// Bearer credential; following a redirect would leak it to an unintended host).
enum PushRelay {
    static let base = URL(string: "https://api.useshepherd.app")!

    struct Registration: Codable, Sendable {
        let id: String
        let sendToken: String
        let manageToken: String
    }

    // MARK: - Session

    /// An ephemeral session that rejects redirects and has bounded timeouts.
    /// Tests inject their own; production uses this shared instance.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }()

    /// Rejects any redirect so a Bearer token is never forwarded to an unexpected host.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirectDelegate()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil // reject
        }
    }

    // MARK: - Validation

    /// Registration ids must look like UUIDs before we put them into URL paths.
    private static func validateRegistrationID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else {
            throw PushError.network("Relay returned an invalid registration id.")
        }
    }

    /// Send and manage tokens are exactly 32 bytes encoded as hex.
    private static func validateHexToken(_ token: String) throws {
        guard token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw PushError.network("Relay returned an invalid credential.")
        }
    }

    /// Validate a decoded registration before using its fields to build authenticated URLs.
    private static func validated(_ reg: Registration) throws -> Registration {
        try validateRegistrationID(reg.id)
        try validateHexToken(reg.sendToken)
        try validateHexToken(reg.manageToken)
        return reg
    }

    // MARK: - Registration

    /// POST a new registration. Only on explicit user opt-in per host.
    static func register(deviceToken: String, environment: PushEnvironment, hostID: UUID,
                         credential: PushKeychain.Credential,
                         session: URLSession? = nil) async throws -> Registration {
        _ = try validated(Registration(id: credential.registrationID, sendToken: credential.sendToken,
                                       manageToken: credential.manageToken))
        let s = session ?? defaultSession
        var request = URLRequest(url: base.appendingPathComponent("api/push/registrations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "deviceToken": deviceToken,
            "environment": environment.rawValue,
            "hostID": hostID.uuidString.lowercased(),
            "id": credential.registrationID,
            "sendToken": credential.sendToken,
            "manageToken": credential.manageToken,
        ]
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await s.data(for: request)
        try check(response)
        // Decode bound only — URLSession buffers the full response in memory; the 10s
        // resource timeout is the transport bound.
        let registration = try validated(decodeBounded(Registration.self, from: data))
        guard registration.id == credential.registrationID,
              registration.sendToken == credential.sendToken,
              registration.manageToken == credential.manageToken else {
            throw PushError.network("Relay returned unexpected credentials.")
        }
        return registration
    }

    /// PATCH an existing registration (token refresh or periodic renew within 90d expiry).
    /// Returns `true` on success (2xx), `false` on 401 (expired/invalidated — caller should
    /// re-register with the persisted identity). Other errors throw.
    @discardableResult
    static func update(registrationID: String, manageToken: String,
                       deviceToken: String, environment: PushEnvironment,
                       session: URLSession? = nil) async throws -> Bool {
        try validateRegistrationID(registrationID)
        let s = session ?? defaultSession
        var request = URLRequest(url: base.appendingPathComponent("api/push/registrations/\(registrationID)"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(manageToken)", forHTTPHeaderField: "Authorization")
        let body: [String: String] = [
            "deviceToken": deviceToken,
            "environment": environment.rawValue,
        ]
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await s.data(for: request)
        let code = statusCode(response)
        if code == 401 { return false }
        try check(response)
        return true
    }

    /// DELETE revokes the registration on the relay.
    /// - 204 → revoked (includes already-deleted or expired registrations — gone either way).
    /// - 401 → wrong credential for a **still-active** registration. The caller must NOT
    ///   discard the credential or claim the registration is gone. Throws `PushError.relay(401)`.
    static func revoke(registrationID: String, manageToken: String,
                       session: URLSession? = nil) async throws {
        try validateRegistrationID(registrationID)
        let s = session ?? defaultSession
        var request = URLRequest(url: base.appendingPathComponent("api/push/registrations/\(registrationID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(manageToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await s.data(for: request)
        guard statusCode(response) == 204 else { throw PushError.relay(statusCode(response)) }
    }

    // MARK: - Helpers

    private static func statusCode(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PushError.network("No HTTP response from relay.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PushError.relay(http.statusCode)
        }
    }

    /// Decode bound: rejects unreasonably large JSON before parsing. The transport memory
    /// bound is the URLSession's 10-second resource timeout, not this check.
    private static func decodeBounded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= 16_384 else { throw PushError.network("Relay response too large.") }
        return try JSONDecoder().decode(type, from: data)
    }
}

enum PushError: LocalizedError {
    case network(String)
    case relay(Int)
    case noDeviceToken
    case permissionDenied
    case keychainFailure(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail): "Network error: \(detail)"
        case .relay(let code): "The relay returned an error (\(code)). Try again."
        case .noDeviceToken: "No device token available. Check notification permissions in Settings."
        case .permissionDenied: "Notification permission was denied. Enable it in the Settings app."
        case .keychainFailure(let detail): "Could not save push credentials: \(detail)"
        }
    }
}

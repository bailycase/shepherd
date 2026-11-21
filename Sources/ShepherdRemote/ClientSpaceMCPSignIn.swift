import Foundation
import ShepherdProtocol

/// A sign-in belongs to a space and a host, not to the view that started it.
@MainActor
public enum ClientSpaceMCPSignIn {
    public static let timeout: Duration = .seconds(300)
    public typealias Send = @MainActor (ProjectMCPAction) async throws -> ProjectMCPResult

    public static func run(server: String, send: Send, authorize: @MainActor (URL, Duration) async throws -> String,
                           wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) async throws {
        let deadline = ContinuousClock.now + timeout
        // A lost login reply doesn't give us a run ID. Never start another login on its behalf.
        var result = try await send(.login(server: server))
        func resume(_ action: ProjectMCPAction) async throws -> ProjectMCPResult {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                do { return try await send(action) }
                catch RemoteHostClientError.disconnected {}
                catch RemoteHostClientError.timeout {}
                catch RemoteHostClientError.rejected(code: "not_sent", message: _) {}
                try await wait()
            }
            throw expired
        }
        guard let id = result.id else { throw ProjectFileError("protocol", "The host didn't start a sign-in.") }
        do {
            var submitted = false
            while result.phase == .waiting {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw expired }
                if let raw = result.authorizationURL, !submitted {
                    guard let url = URL(string: raw), ["http", "https"].contains(url.scheme), url.host != nil else {
                        throw ProjectFileError("callback", "The host didn't provide a valid sign-in page.")
                    }
                    let redirect = try await authorize(url, ContinuousClock.now.duration(to: deadline))
                    submitted = true
                    result = try await resume(.complete(id: id, redirectURL: redirect))
                } else {
                    try await wait()
                    result = try await resume(.poll(id: id))
                }
            }
            guard result.phase == .done else { throw ProjectFileError("sign_in", result.message ?? "Sign-in failed. Try again.") }
        } catch {
            _ = try? await send(.cancel(id: id))
            throw error
        }
    }

    private static var expired: ProjectFileError { .init("timeout", "Signing in didn't finish within 300 seconds.") }
}

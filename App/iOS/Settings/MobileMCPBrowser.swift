import AuthenticationServices
import os
import ShepherdRemote
import SwiftUI

/// Presents from the window that owns the settings view, including on iPad and Duo.
@MainActor
final class MobileMCPBrowser: UIView, ASWebAuthenticationPresentationContextProviding {
    private weak var anchor: UIWindow?
    private var session: ASWebAuthenticationSession?
    private var activeHandoff: URL?
    private var pending: CheckedContinuation<URL, any Error>?

    func authorize(_ authorization: URL, remaining: Duration) async throws -> String {
        guard let window else { throw MobileMCPBrowserError.noWindow }
        // The provider still redirects to pi's registered loopback URL. Only an opaque
        // nonce goes through the app scheme; the original callback stays in memory.
        let handoff = URL(string: "shepherd://mcp-callback/\(UUID())")!
        let redirect = OSAllocatedUnfairLock<String?>(initialState: nil)
        let relay = try MCPCallbackRelay(authorizationURL: authorization, handoff: handoff) { answer in
            redirect.withLock { if $0 == nil { $0 = answer } }
        }
        defer { relay.cancel() }
        try await relay.start()
        anchor = window
        activeHandoff = handoff
        defer { anchor = nil; activeHandoff = nil }
        let expiry = Task {
            try await Task.sleep(for: remaining)
            finish(.failure(MobileMCPBrowserError.expired))
        }
        defer { expiry.cancel() }
        let callback = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let session = ASWebAuthenticationSession(url: authorization, callback: .customScheme("shepherd")) { [weak self] callback, error in
                    Task { @MainActor in
                        guard self?.activeHandoff == handoff else { return }
                        if let callback { self?.finish(.success(callback)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self?.finish(.failure(CancellationError()))
                        } else { self?.finish(.failure(MobileMCPBrowserError.unavailable)) }
                    }
                }
                session.presentationContextProvider = self
                self.session = session
                if !session.start() { finish(.failure(MobileMCPBrowserError.unavailable)) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
        guard callback == handoff, let answer = redirect.withLock({ $0 }) else { throw MobileMCPBrowserError.invalidCallback }
        return answer
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor! // Retained by authorize for the duration of the session.
    }

    private func finish(_ result: Result<URL, any Error>) {
        let continuation = pending
        pending = nil
        session?.cancel()
        session = nil
        continuation?.resume(with: result)
    }
}

private enum MobileMCPBrowserError: LocalizedError {
    case noWindow, expired, unavailable, invalidCallback

    var errorDescription: String? {
        switch self {
        case .noWindow, .unavailable: "Couldn't open the sign-in page. Try again."
        case .expired: "Signing in didn't finish in time. Try again."
        case .invalidCallback: "The callback didn't match this sign-in. Try again."
        }
    }
}

struct MobileMCPBrowserAnchor: UIViewRepresentable {
    let browser: MobileMCPBrowser
    func makeUIView(context: Context) -> MobileMCPBrowser { browser }
    func updateUIView(_ view: MobileMCPBrowser, context: Context) {}
}

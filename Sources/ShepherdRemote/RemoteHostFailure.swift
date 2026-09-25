import Foundation
import ShepherdProtocol

/// Why a client could not reach a host, as the Mac's remote hosts and the iOS client both say
/// it: one sentence for people, a short word for a status row, the technical reason kept apart
/// for where there is room for it, and whether trying again on its own could help.
public struct RemoteHostFailure: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Nothing answered: refused, unreachable, timed out, or the name did not resolve.
        case unreachable
        /// A live connection dropped.
        case lost
        /// The host refused the token.
        case tokenRefused
        /// The host speaks another protocol version; `hostNewer` is nil when it did not say which.
        case versionMismatch(hostNewer: Bool?)
        /// No token is saved for the host.
        case tokenMissing
        /// The saved token cannot be read now (the iOS Keychain while the device is locked).
        case tokenUnreadable
        case other

        /// A status row's word ("Unreachable", "Token refused").
        public var headline: String {
            switch self {
            case .unreachable, .lost, .other: "Unreachable"
            case .tokenRefused: "Token refused"
            case .versionMismatch: "Update needed"
            case .tokenMissing: "No token"
            case .tokenUnreadable: "Token locked"
            }
        }
    }

    public var kind: Kind
    /// The client's own reason ("connect failed: Connection refused (errno 61)").
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// A failed `RemoteHostClient.connect`.
    public init(_ error: any Error) {
        let detail = String(describing: error)
        guard let error = error as? RemoteHostClientError else {
            self.init(kind: .other, detail: detail)
            return
        }
        switch error {
        case .resolveFailed, .timeout:
            self.init(kind: .unreachable, detail: detail)
        case .system(let call, let err):
            self.init(kind: call == "connect" && err != EISCONN ? .unreachable : .other, detail: detail)
        case .rejected(RemoteProtocol.unauthorizedCode, _):
            self.init(kind: .tokenRefused, detail: detail)
        case .rejected(RemoteProtocol.versionMismatchCode, let message):
            self.init(kind: .versionMismatch(hostNewer: Self.hostVersion(message).map { $0 > RemoteProtocol.version }), detail: detail)
        case .disconnected:
            self.init(kind: .lost, detail: detail)
        case .rejected, .outcomeUnknown:
            self.init(kind: .other, detail: detail)
        }
    }

    /// A live connection's `onDisconnected` reason.
    public init(disconnect reason: String) {
        self.init(kind: .lost, detail: reason)
    }

    /// Whether reconnecting with backoff could help. A refused token or another protocol
    /// version fails the same way every time, so those wait for the user (Edit, Retry).
    public var retries: Bool {
        switch kind {
        case .unreachable, .lost, .other: true
        case .tokenRefused, .versionMismatch, .tokenMissing, .tokenUnreadable: false
        }
    }

    public var headline: String { kind.headline }

    /// What happened and what to do, naming the host as the user named it.
    public func message(host: String) -> String {
        switch kind {
        case .unreachable: "Shepherd isn't running on \(host), or it can't be reached."
        case .lost: "Lost the connection to \(host)."
        case .tokenRefused: "\(host) refused the token. Edit the host to paste its current token."
        case .versionMismatch(hostNewer: true): "\(host) runs a newer Shepherd. Update Shepherd here to connect."
        case .versionMismatch(hostNewer: false): "\(host) runs an older Shepherd. Update Shepherd there to connect."
        case .versionMismatch(hostNewer: nil): "\(host) runs another version of Shepherd. Update both to connect."
        case .tokenMissing: "The token is missing. Edit the host to add it."
        case .tokenUnreadable: "The saved token can't be read until this device is unlocked."
        case .other: "Couldn't connect to \(host)."
        }
    }

    /// The host's version from its refusal ("host speaks protocol 3").
    static func hostVersion(_ message: String) -> Int? {
        message.split(separator: " ").last.flatMap { Int($0) }
    }
}

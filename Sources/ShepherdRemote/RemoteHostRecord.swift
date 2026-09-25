import Foundation

/// A host a client connects to: where it listens and what the user calls it. The bearer token
/// is kept apart (the iOS client keeps it in the Keychain, keyed by `id`), so a record is safe
/// to save in preferences.
public struct RemoteHostRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var port: UInt16

    public init(id: UUID = UUID(), name: String, address: String, port: UInt16) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
    }

    /// The listener's default port (Shepherd Nightly serves on 7434).
    public static let defaultPort: UInt16 = 7433

    /// Saved records, in the order the user added them. Unreadable data is no hosts, never a crash.
    public static func decodeList(_ data: Data?) -> [RemoteHostRecord] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RemoteHostRecord].self, from: data)) ?? []
    }

    public static func encodeList(_ records: [RemoteHostRecord]) -> Data {
        (try? JSONEncoder().encode(records)) ?? Data("[]".utf8)
    }

    /// The single host the first iOS client saved (`{name, host, port}`), as a record with `id`.
    /// Nil when there is none or it cannot be read.
    public static func migrating(legacy data: Data?, id: UUID) -> RemoteHostRecord? {
        struct Legacy: Decodable {
            var name: String
            var host: String
            var port: UInt16
        }
        guard let data, let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
              let entry = try? RemoteHostEntry(name: legacy.name, address: legacy.host, port: String(legacy.port), token: nil)
        else { return nil }
        return RemoteHostRecord(id: id, name: entry.name, address: entry.address, port: entry.port)
    }
}

/// What someone typed into a host form, trimmed and checked.
public struct RemoteHostEntry: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case address
        case port
        case token

        public var description: String {
            switch self {
            case .address: "Enter a hostname or IP address."
            case .port: "Enter a port from 1 to 65535."
            case .token: "Paste the host's token."
            }
        }
    }

    public var name: String
    public var address: String
    public var port: UInt16
    /// Nil keeps the token already saved (editing a host without retyping it).
    public var token: String?

    /// `token` nil or blank means "keep the saved one"; pass `requireToken` for a new host.
    /// An empty name falls back to the address.
    public init(name: String, address: String, port: String, token: String?, requireToken: Bool = false) throws(Problem) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(where: \.isWhitespace) else { throw .address }
        guard let port = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else { throw .port }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = token?.isEmpty == false ? token : nil
        if requireToken, kept == nil { throw .token }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.isEmpty ? address : name
        self.address = address
        self.port = port
        self.token = kept
    }
}

/// One host connection's state as a client shows it.
public enum RemoteHostPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    public var isConnected: Bool { self == .connected }

    /// The word a status pill shows: "Connected", "Connecting", or "Offline".
    public var word: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected, .failed: "Offline"
        }
    }

    /// Why it is offline, when a connection failed.
    public var failure: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// Reconnect delays: 1, 2, 4… seconds, capped at 30, back to 1 after a success.
public struct RemoteReconnectBackoff: Equatable, Sendable {
    public let initial: Duration
    public let cap: Duration
    public private(set) var upcoming: Duration

    public init(initial: Duration = .seconds(1), cap: Duration = .seconds(30)) {
        self.initial = initial
        self.cap = cap
        upcoming = initial
    }

    /// The delay before the next attempt; the one after it doubles, up to the cap.
    public mutating func next() -> Duration {
        let delay = upcoming
        upcoming = min(upcoming * 2, cap)
        return delay
    }

    public mutating func reset() { upcoming = initial }
}

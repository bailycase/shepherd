import Foundation

/// Typed identifier: a UUID-backed string distinguished at compile time by its marker.
public struct Identifier<Marker>: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }
}

extension Identifier: Codable {
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SpaceMarker: Sendable {}
public enum TabMarker: Sendable {}
public enum PaneMarker: Sendable {}
public enum AgentMarker: Sendable {}
public enum SessionMarker: Sendable {}
public enum AutomationMarker: Sendable {}

public typealias SpaceID = Identifier<SpaceMarker>
public typealias TabID = Identifier<TabMarker>
public typealias PaneID = Identifier<PaneMarker>
public typealias AgentID = Identifier<AgentMarker>
public typealias SessionID = Identifier<SessionMarker>
public typealias AutomationID = Identifier<AutomationMarker>


/// Parameters for spawning a PTY session. `command` empty means the default
/// login shell.
public struct CreateSessionParams: Codable, Hashable, Sendable {
    public var cwd: String
    public var command: [String]
    public var cols: Int
    public var rows: Int
    public var env: [String: String]?

    public init(cwd: String, command: [String] = [], cols: Int = 80, rows: Int = 24, env: [String: String]? = nil) {
        self.cwd = cwd
        self.command = command
        self.cols = cols
        self.rows = rows
        self.env = env
    }
}

public struct SessionInfo: Codable, Hashable, Sendable {
    public var id: SessionID
    public var cwd: String
    public var command: [String]
    public var cols: Int
    public var rows: Int
    public var isAlive: Bool

    public init(id: SessionID, cwd: String, command: [String], cols: Int, rows: Int, isAlive: Bool) {
        self.id = id
        self.cwd = cwd
        self.command = command
        self.cols = cols
        self.rows = rows
        self.isAlive = isAlive
    }
}

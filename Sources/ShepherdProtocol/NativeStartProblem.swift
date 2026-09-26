import Foundation

/// Why an agent's pi stopped before it served its thread (DESIGN.md › Thread › Can't start): the
/// host names the cause from pi's exit and its last lines on stderr, keeps the agent, and says so
/// in the thread's snapshot (`NativeThreadSnapshot.startProblem`) until pi starts again.
public struct NativeStartProblem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// pi found no model it can use ("No models available").
        case notSignedIn
        /// An extension failed to load, which ends pi in every mode.
        case extensionFailed
        /// The shell found no pi to run (exit 127 or 126).
        case engineMissing
        /// pi didn't find the conversation it was resuming and would have started a new one under
        /// its id, so Shepherd stopped it before it wrote anything.
        case resumedAsNew
        /// Anything else: pi's own words say why.
        case exited

        /// A cause a newer host names reads as `exited`, whose lines still say why.
        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .exited
        }
    }

    /// The most lines of pi's stderr a problem carries.
    public static let maxLines = 6

    public var kind: Kind
    /// pi's exit code; nil when a signal ended it (Shepherd's stop included).
    public var exitCode: Int32?
    /// pi's last lines on stderr, oldest first, without colour codes or blank lines.
    public var lines: [String]

    public init(kind: Kind, exitCode: Int32? = nil, lines: [String] = []) {
        self.kind = kind
        self.exitCode = exitCode
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case kind, exitCode, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .exited
        exitCode = try? c.decodeIfPresent(Int32.self, forKey: .exitCode)
        lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
    }
}

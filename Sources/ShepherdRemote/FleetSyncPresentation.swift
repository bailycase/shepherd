import Foundation
import ShepherdProtocol

/// Settings ▸ Fleet's sync line (FleetSettings): where sync stands, in the words the board draws.
/// "In sync on This Mac and Mac mini · Mac Studio is asleep and catches up when it wakes". Shared by
/// the Mac and iOS; derived once per change from `FleetSyncStatus`.
public struct FleetSyncLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Every linked Mac holds the same.
        case inSync
        /// Something is still moving to or from a linked Mac.
        case catchingUp
        /// No Mac is linked: nothing can sync until one is back.
        case alone
    }

    public var tone: Tone
    /// The first part, in the page's secondary text: "In sync on This Mac and Mac mini".
    public var lead: String?
    /// After a " · ", dimmer: "Mac Studio is asleep and catches up when it wakes".
    public var tail: String?
    /// What the first sync replaced on this Mac, on a line of its own.
    public var notice: String?

    public init(tone: Tone, lead: String? = nil, tail: String? = nil, notice: String? = nil) {
        self.tone = tone
        self.lead = lead
        self.tail = tail
        self.notice = notice
    }
}

public enum FleetSyncPresentation {
    /// The line for `status`; nil while this Mac is paired with none (nothing to say).
    public static func line(_ status: FleetSyncStatus) -> FleetSyncLine? {
        guard !status.peers.isEmpty else { return nil }
        let inSync = status.peers.filter { $0.state == .inSync }.map(\.name)
        let catching = status.peers.filter { $0.state == .catchingUp }.map(\.name)
        let away = status.peers.filter { $0.state == .offline }.map(\.name)

        var lead: String?
        var tail: [String] = []
        let tone: FleetSyncLine.Tone
        if !catching.isEmpty {
            tone = .catchingUp
            lead = "Catching up with \(list(catching))"
        } else if !inSync.isEmpty {
            tone = .inSync
            lead = "In sync on \(list(["This Mac"] + inSync))"
        } else {
            tone = .alone
        }
        if !catching.isEmpty, !inSync.isEmpty { tail.append("In sync on \(list(["This Mac"] + inSync))") }
        if !away.isEmpty {
            tail.append(away.count == 1 ? "\(away[0]) is asleep and catches up when it wakes"
                                        : "\(list(away)) are asleep and catch up when they wake")
        }
        return FleetSyncLine(tone: tone, lead: lead, tail: tail.isEmpty ? nil : tail.joined(separator: " · "), notice: status.notice)
    }

    /// "Mac mini", "Mac mini and Mac Studio", "A, B and C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

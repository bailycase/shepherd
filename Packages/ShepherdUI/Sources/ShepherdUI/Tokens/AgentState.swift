import SwiftUI

/// The one state enum every status surface is driven by (Status board): pills, dots, glyphs,
/// step strips, toasts. The app maps its own lifecycle (agent status, subagent runs, tool calls)
/// onto it. Only `attention` animates.
public enum AgentState: String, CaseIterable, Hashable, Sendable {
    /// Working: a turn, tool, or run in progress.
    case running
    /// Needs you: a question, an approval the asker offered, a blocked agent.
    case attention
    case done
    case failed
    /// Running too long without progress.
    case stuck
    /// Waiting to start.
    case queued
    case idle

    /// The state's word ("Needs you"). A status is always a glyph or dot plus a word.
    public var label: String {
        switch self {
        case .running: "Running"
        case .attention: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .stuck: "Stuck"
        case .queued: "Queued"
        case .idle: "Idle"
        }
    }

    /// The SF Symbol for the state where a glyph stands alone (tool rows, run ledgers). Running
    /// draws a spinner instead where one fits (`NWStateGlyph`).
    public var symbolName: String {
        switch self {
        case .running: "circle.dotted"
        case .attention: "exclamationmark.circle"
        case .done: "checkmark"
        case .failed: "xmark"
        case .stuck: "exclamationmark.triangle"
        case .queued: "circle"
        case .idle: "circle.fill"
        }
    }

    /// Whether the dot is drawn hollow (a ring) rather than filled.
    public var isHollow: Bool { self == .queued }

    /// Whether the state glows (the only animated state).
    public var glows: Bool { self == .attention }

    /// Dots, glyphs, spinners, bars.
    @MainActor public var color: Color {
        let nw = Color.nw
        return switch self {
        case .running: nw.running
        case .attention: nw.lantern
        case .done: nw.done
        case .failed, .stuck: nw.failed
        case .queued, .idle: nw.textTertiary
        }
    }

    /// The word on a pill or banner title.
    @MainActor public var textColor: Color {
        let nw = Color.nw
        return switch self {
        case .running: nw.running
        case .attention: nw.lanternText
        case .done: nw.done
        case .failed, .stuck: nw.failed
        case .queued, .idle: nw.textSecondary
        }
    }

    /// The pill and banner fill; queued and idle have none (they are outlined).
    @MainActor public var tint: Color? {
        let nw = Color.nw
        return switch self {
        case .running: nw.runningTint
        case .attention: nw.lanternTint
        case .done: nw.doneTint
        case .failed, .stuck: nw.failedTint
        case .queued, .idle: nil
        }
    }
}

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
    /// draws a spinner instead where one fits (`SHStateGlyph`).
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
        let sh = Color.sh
        return switch self {
        case .running: sh.running
        case .attention: sh.lantern
        case .done: sh.done
        case .failed, .stuck: sh.failed
        case .queued, .idle: sh.textTertiary
        }
    }

    /// The word on a pill or banner title.
    @MainActor public var textColor: Color {
        let sh = Color.sh
        return switch self {
        case .running: sh.running
        case .attention: sh.lanternText
        case .done: sh.done
        case .failed, .stuck: sh.failed
        case .queued, .idle: sh.textSecondary
        }
    }

    /// The pill and banner fill; queued and idle have none (they are outlined).
    @MainActor public var tint: Color? {
        let sh = Color.sh
        return switch self {
        case .running: sh.runningTint
        case .attention: sh.lanternTint
        case .done: sh.doneTint
        case .failed, .stuck: sh.failedTint
        case .queued, .idle: nil
        }
    }
}

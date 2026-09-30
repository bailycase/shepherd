import Foundation
import ShepherdProtocol

/// The three ways to send a message while pi works, and the words each goes by (the Send menu's
/// rows, Settings ▸ Agents' choices and the touch clients' menu), in the order they are offered:
/// from the gentlest to the most urgent.
public enum NativeSendChoice: String, CaseIterable, Identifiable, Sendable {
    /// It waits in Up next and goes when the turn ends.
    case wait
    /// pi reads it once its current tool calls finish, before its next step.
    case nextStep
    /// pi stops what it is doing, as Stop does, and the message goes at once as the next turn.
    case now

    public var id: String { rawValue }

    public var delivery: NativeThreadDelivery {
        switch self {
        case .wait: .followUp
        case .nextStep: .steer
        case .now: .interrupt
        }
    }

    public init(delivery: NativeThreadDelivery) {
        switch delivery {
        case .followUp: self = .wait
        case .steer: self = .nextStep
        case .interrupt: self = .now
        }
    }

    public var title: String {
        switch self {
        case .wait: "Wait for the turn to end"
        case .nextStep: "Steer at the next step"
        case .now: "Steer now"
        }
    }

    /// What the choice does, in a sentence.
    public var detail: String {
        switch self {
        case .wait: "Goes when the agent finishes this turn."
        case .nextStep: "Lands once the agent’s current tool calls finish, before its next step."
        case .now: "Stops what the agent is doing and sends this at once."
        }
    }

    /// The queued row's Steer now action and the ••• menu's Steer all now say the same.
    public static let steerNowHelp = "Stop the agent and send this now"
    public static let steerAllNowHelp = "Stop the agent and send these now, in order"
}

import Foundation
import ShepherdProtocol

/// The two ways to send a message while pi works, and the words each goes by (the Send menu's
/// rows and the touch clients' menu), in the order they are offered. Return queues; Steer now is
/// the only way to steer. (`NativeThreadDelivery.steer` stays on the wire for older clients, and
/// for Steer now against a host that can't stop pi, but no surface offers it.)
public enum NativeSendChoice: String, CaseIterable, Identifiable, Sendable {
    /// It waits in Up next and goes when the turn ends.
    case wait
    /// pi stops what it is doing, as Stop does, and the message goes at once as the next turn.
    case now

    public var id: String { rawValue }

    public var delivery: NativeThreadDelivery {
        switch self {
        case .wait: .followUp
        case .now: .interrupt
        }
    }

    public var title: String {
        switch self {
        case .wait: "Wait for the turn to end"
        case .now: "Steer now"
        }
    }

    /// What the choice does, in a sentence.
    public var detail: String {
        switch self {
        case .wait: "Goes when the agent finishes this turn."
        case .now: "Stops what the agent is doing and sends this at once."
        }
    }

    /// The composer's corner button is Stop, not Send, while pi works and there is nothing to
    /// send. Any input counts: words, attached files, images, design references, page elements.
    public static func stopsInPlaceOfSend(running: Bool, hasInput: Bool) -> Bool { running && !hasInput }

    /// The queued row's Steer now action and the ••• menu's Steer all now say the same.
    public static let steerNowHelp = "Stop the agent and send this now"
    public static let steerAllNowHelp = "Stop the agent and send these now, in order"
}

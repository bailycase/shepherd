import Foundation
import ShepherdCore

/// Closing a thread from a client before its host has answered: the row leaves lists and the screen
/// leaves the thread at once, and the host's answer then settles it. Presentation only: the host's
/// agent, draft and checkout stay until it retires the agent.
public enum ThreadClosing {
    /// What a failed close means for what the person sees.
    public enum Outcome: Equatable, Sendable {
        /// The host refused, or nothing was sent: nothing happened, so the row returns, and the screen
        /// with it when the person has not moved on.
        case refused(String)
        /// The request may have been taken (a dropped connection, a timeout, a status the host never
        /// gave): the host's own state and status decide, so the row returns where the host still has it,
        /// the screen stays where the person is, and the delete is not sent again.
        case unknown(String)
    }

    /// A refusal a close's own work found after the host answered (a finished worktree operation that
    /// failed): it left the agent where it was.
    public struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// An outcome the close's own work could not tell (a worktree operation whose start or status went unanswered).
    public struct Unanswered: Error, Equatable, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public static func outcome(of error: Error) -> Outcome {
        if let refusal = error as? Refusal { return .refused(refusal.description) }
        if let unanswered = error as? Unanswered { return .unknown(unanswered.description) }
        if case RemoteHostClientError.rejected(_, let message) = error { return .refused(message) }
        return .unknown("The host didn’t answer (\(error)). Check the thread before trying again.")
    }

    /// Where the screens were, and where closing left them. A refusal puts the screens back only when the
    /// person is still where closing left them, so a later move is never undone.
    public struct Rollback<Place: Equatable>: Equatable {
        public let before: Place
        public let after: Place

        public init(before: Place, after: Place) {
            self.before = before
            self.after = after
        }

        /// The place to go back to, or nil when `current` is not where closing left the person.
        public func restoring(from current: Place) -> Place? { current == after ? before : nil }
    }
}

extension ShepherdState {
    /// The state as lists draw it, without the agents a client is closing. Everything else stays.
    public func hiding(_ closing: Set<AgentID>) -> ShepherdState {
        guard !closing.isEmpty, agents.contains(where: { closing.contains($0.id) }) else { return self }
        var state = self
        state.agents.removeAll { closing.contains($0.id) }
        return state
    }
}

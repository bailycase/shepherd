import Foundation
import ShepherdProtocol

/// The code window of a Mac that is joining a fleet: open while its Join screen is, which is the
/// person's consent. Only the code's SHA-256, its expiry and the tries left are kept, in memory.
/// A code is single use, lasts `FleetProtocol.codeLifetime` and dies after
/// `FleetProtocol.maxCodeAttempts` wrong tries.
struct FleetJoinWindow: Equatable, Sendable {
    enum Attempt: Equatable, Sendable {
        case accepted
        case wrong(attemptsLeft: Int)
        case lockedOut
        case expired
    }

    private(set) var codeHash: String
    private(set) var expiresAt: Date
    private(set) var attemptsLeft: Int

    /// A new window and the code to show: `FleetProtocol.codeLength` digits from the system's
    /// secure generator.
    static func open(now: Date = Date(), lifetime: TimeInterval = FleetProtocol.codeLifetime,
                     attempts: Int = FleetProtocol.maxCodeAttempts) -> (window: FleetJoinWindow, code: String) {
        let limit = (0..<FleetProtocol.codeLength).reduce(1) { value, _ in value * 10 }
        let code = String(format: "%0\(FleetProtocol.codeLength)d", Int.random(in: 0..<limit))
        return (FleetJoinWindow(codeHash: FleetProtocol.hash(code), expiresAt: now.addingTimeInterval(lifetime), attemptsLeft: attempts), code)
    }

    /// Spaces and dashes a person types between digits don't count.
    static func normalized(_ typed: String) -> String { typed.filter(\.isNumber) }

    /// Judges one try. The window is spent by `accepted` and `lockedOut`: the caller drops it.
    mutating func attempt(_ typed: String, now: Date = Date()) -> Attempt {
        guard now < expiresAt else { return .expired }
        guard attemptsLeft > 0 else { return .lockedOut }
        // Compared as hashes, in time that doesn't depend on how many leading digits match.
        if RemoteToken.matches(FleetProtocol.hash(Self.normalized(typed)), expected: codeHash) { return .accepted }
        attemptsLeft -= 1
        return attemptsLeft == 0 ? .lockedOut : .wrong(attemptsLeft: attemptsLeft)
    }
}

import Foundation
import ShepherdProtocol

// A viewer's claim on one remote thread's browser (docs/browser.md › Remote › The agent drives the
// page you see): when to claim it and when to let go, from what the Browser tab and the connection
// do. It is a value with no timers and no sockets, so the rules are tested with the clock handed in,
// and the Mac app and the iPad share them: each asks it what to send, and tells it what came back.

public struct BrowserDriveClaimant: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Not claimed: the tab is out of sight, the connection is down, or the host took it back.
        case idle
        /// A claim is on its way to the host.
        case claiming
        /// The host runs the agent's browser tools here.
        case owned
        /// Another viewer claimed it after this one. It stays theirs until this tab is shown again.
        case superseded
        /// The host refused the claim (`code`); the next show or reconnect tries again.
        case refused(code: String)
    }

    /// What the owner of the claim must send the host.
    public enum Action: Equatable, Sendable {
        case claim
        case release
    }

    public private(set) var phase: Phase = .idle
    /// The Browser tab is on screen.
    public private(set) var shown = false
    /// The connection is up and the host offers the drive (and the tunnel its page loads through).
    public private(set) var connected = false
    /// When the tab last went out of sight, while it is.
    public private(set) var hiddenSince: Date?
    /// How long a hidden tab keeps its claim.
    public let grace: TimeInterval

    public init(grace: TimeInterval = BrowserDriveLimits.hiddenGraceSeconds) {
        self.grace = grace
    }

    /// The host has the agent's browser run here, or is being asked to.
    public var holds: Bool { phase == .owned || phase == .claiming }

    /// The tab is on screen. A claim is made unless this viewer holds it already, or another viewer
    /// has it and this show is not a new one.
    public mutating func tabShown() -> Action? {
        let wasShown = shown
        shown = true
        hiddenSince = nil
        guard connected else { return nil }
        switch phase {
        case .idle, .refused:
            phase = .claiming
            return .claim
        case .superseded where !wasShown:
            phase = .claiming
            return .claim
        case .superseded, .claiming, .owned:
            return nil
        }
    }

    /// The tab went out of sight (another tab, the pane closed, another thread on screen). Nothing
    /// is let go yet: `release(now:)` does that once the grace has passed.
    public mutating func tabHidden(now: Date) {
        guard shown else { return }
        shown = false
        hiddenSince = now
    }

    /// When the claim is let go if the tab is not shown again: the moment to call `release(now:)`.
    public var releaseDeadline: Date? {
        guard !shown, holds, let hiddenSince else { return nil }
        return hiddenSince.addingTimeInterval(grace)
    }

    /// The grace has passed with the tab hidden: let the agent's browser go back to the host.
    public mutating func release(now: Date) -> Action? {
        guard let deadline = releaseDeadline, deadline <= now else { return nil }
        phase = .idle
        return .release
    }

    /// The connection came up (with the drive on offer), or went away (the host drops every claim
    /// with it).
    public mutating func connection(up: Bool) -> Action? {
        connected = up
        guard up else {
            if phase != .idle { phase = .idle }
            return nil
        }
        guard shown else { return nil }
        switch phase {
        case .idle, .refused:
            phase = .claiming
            return .claim
        case .claiming, .owned, .superseded:
            return nil
        }
    }

    /// The host answered the claim: this viewer owns the agent's browser. A claim answered after the
    /// tab was let go (it went out of sight and its grace passed) is not one the viewer holds.
    @discardableResult
    public mutating func claimed() -> Bool {
        guard phase == .claiming else { return false }
        phase = .owned
        return true
    }

    /// The host refused the claim, or another viewer took it before the answer came.
    public mutating func claimFailed(code: String) {
        guard phase == .claiming else { return }
        phase = code == BrowserDriveEnd.superseded ? .superseded : .refused(code: code)
    }

    /// The host says this viewer no longer owns it (`BrowserDriveEnd`).
    public mutating func ended(reason: String) {
        phase = reason == BrowserDriveEnd.superseded ? .superseded : .idle
    }
}

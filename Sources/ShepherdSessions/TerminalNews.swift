import Foundation

/// How far a terminal's news has got: output worth a dot on a tab that is off screen
/// (DESIGN.md › Terminal panel). Every read of a PTY advances its output sequence, the attach
/// watermark, but a shell or a TUI answers a new window size (SIGWINCH) by drawing its screen
/// again, and a redraw is not news. So output read within `redrawWindow` of a resize the PTY
/// received advances nothing here; a command still printing after that window does.
struct TerminalNews: Equatable, Sendable {
    /// Long enough for a loaded machine's shell to redraw its prompt; short enough that a
    /// command printing on its own is seen soon after.
    static let redrawWindow: Duration = .seconds(1)

    private(set) var sequence: UInt64 = 0
    private var redrawUntil: ContinuousClock.Instant?

    /// The PTY took a size (a new grid, or a same-size nudge that signals SIGWINCH anyway).
    mutating func resized(at now: ContinuousClock.Instant) {
        redrawUntil = now + Self.redrawWindow
    }

    /// One read of the PTY's output.
    mutating func output(at now: ContinuousClock.Instant) {
        if let redrawUntil, now < redrawUntil { return }
        redrawUntil = nil
        sequence &+= 1
    }
}

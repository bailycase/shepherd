import Foundation

/// Where one of the app's windows stands, as its scene reports it.
public enum WindowPhase: Sendable, Equatable {
    case active
    /// On screen but not taking input (a system alert, the app switcher), or not yet reported.
    case inactive
    case background
}

/// Rules for an app with several windows over one set of host connections (iPad).
public enum WindowPresence {
    /// Whether the hosts should be connected, given every open window's phase: yes while any
    /// window is active, no once every window is in the background (or none is open), and nil,
    /// leaving the connections as they are, while the rest are only inactive.
    public static func foreground<Phases: Collection<WindowPhase>>(_ phases: Phases) -> Bool? {
        if phases.contains(.active) { return true }
        if phases.allSatisfy({ $0 == .background }) { return false }
        return nil
    }
}

/// A thread shown in another window, for "Send to…".
public struct WindowTarget<Thread: Hashable & Sendable>: Hashable, Sendable {
    public let window: UUID
    public let thread: Thread

    public init(window: UUID, thread: Thread) {
        self.window = window
        self.thread = thread
    }
}

public enum WindowTargets {
    /// The threads other windows show, in the windows' order, each once: not the window asking,
    /// not the thread the text comes from, and not a window showing no thread.
    public static func others<Thread: Hashable & Sendable>(_ windows: [(window: UUID, thread: Thread?)], from window: UUID,
                                                            excluding source: Thread?) -> [WindowTarget<Thread>] {
        var seen: Set<Thread> = []
        var targets: [WindowTarget<Thread>] = []
        for entry in windows where entry.window != window {
            guard let thread = entry.thread, thread != source, seen.insert(thread).inserted else { continue }
            targets.append(WindowTarget(window: entry.window, thread: thread))
        }
        return targets
    }
}

/// Text sent to a thread's composer from somewhere else (another window's message, a drop).
public enum ComposerInsertion {
    /// `text` added to `draft`: the draft itself when it is blank, otherwise after a blank line.
    /// Nothing changes for blank text. Surrounding blank lines are trimmed; the text's own
    /// lines and indentation are kept.
    public static func inserting(_ text: String, into draft: String) -> String {
        let text = trimmingBlankLines(text)
        guard !text.isEmpty else { return draft }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        var head = Substring(draft)
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return head + "\n\n" + text
    }

    private static func trimmingBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        var joined = lines.joined(separator: "\n")
        while let last = joined.last, last.isWhitespace { joined.removeLast() }
        return joined
    }
}

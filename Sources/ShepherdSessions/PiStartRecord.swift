import Foundation
import ShepherdProtocol

/// One agent pi's run, as the server sees it: its lines on stderr (the start's until it serves
/// its thread, then a short tail with times), and whether Shepherd stopped it. Any exit of an
/// agent's pi keeps its agent while the agent exists: one Shepherd asked for with no problem to
/// show, one before it served with the cause its start lines name, one on its own after it
/// served as `.stopped` with its last words (`problem(exitCode:signal:at:)`).
struct PiStartRecord {
    /// Why Shepherd stopped this pi.
    enum Stop: Equatable {
        /// pi said it would start a new conversation in place of the one it was resuming.
        case resumedAsNew
        /// Shepherd needed it stopped (the agent stays, with no problem to show).
        case requested
    }

    /// The pi session this pi was launched to resume; nil for a fresh one, or when the user chose
    /// to start without the check.
    let resuming: String?
    /// pi served its thread.
    private(set) var ready = false
    private(set) var stop: Stop?
    /// Its stderr until it served, without colour codes or blank lines, at most `keptLines` of the newest.
    private(set) var lines: [String] = []

    /// One line pi wrote after it served, and when.
    struct Said: Equatable {
        let at: ContinuousClock.Instant
        let line: String
    }
    /// What pi wrote after it served, oldest first: at most `keptLines` of the newest, each cut to `maxLineLength`.
    private(set) var tail: [Said] = []

    /// Lines kept while pi starts, and after it serves; a problem carries the newest `NativeStartProblem.maxLines`.
    static let keptLines = 40
    static let maxLineLength = 1024
    /// A pi that stopped on its own is read by what it wrote this long before: older lines say nothing about why.
    static let wordsWindow = Duration.seconds(10)

    init(resuming: String? = nil) {
        self.resuming = resuming
    }

    /// An exit keeps the agent even while no pane is bound to it: pi never served, or Shepherd
    /// asked for the stop. A bound agent is kept for any exit (`SessionServer.sessionDidExit`).
    var keepsUnboundAgent: Bool { !ready || stop != nil }

    /// pi serves its thread: what it said while starting is no longer needed, unless Shepherd is
    /// stopping it for what it said. From here on it keeps a tail instead.
    mutating func served() {
        ready = true
        if stop == nil { lines = [] }
    }

    mutating func requestStop() {
        if stop == nil { stop = .requested }
    }

    /// One line pi wrote on stderr, at `at`. True when it says pi is starting a new conversation
    /// under the id it was launched to resume: the caller stops pi before it writes anything. pi
    /// says so only while it starts, but its stderr and its first answers travel on separate
    /// pipes, so the line is honoured even once the thread serves.
    mutating func note(stderr line: String, at: ContinuousClock.Instant = .now) -> Bool {
        let plain = Self.plain(line)
        if !plain.isEmpty {
            if ready {
                tail.append(Said(at: at, line: String(plain.prefix(Self.maxLineLength))))
                if tail.count > Self.keptLines { tail.removeFirst(tail.count - Self.keptLines) }
            } else {
                lines.append(plain)
                if lines.count > Self.keptLines { lines.removeFirst(lines.count - Self.keptLines) }
            }
        }
        guard stop == nil, let resuming, Self.startsNewConversation(plain, id: resuming) else { return false }
        stop = .resumedAsNew
        if ready, !plain.isEmpty { lines = [plain] }
        return true
    }

    /// Why this pi's exit keeps its agent; nil for a stop Shepherd asked for, which is no problem.
    /// `at` is when it exited, for reading a served pi's last words.
    func problem(exitCode: Int32?, signal: Int32? = nil, at exit: ContinuousClock.Instant = .now) -> NativeStartProblem? {
        switch stop {
        case .resumedAsNew: Self.classify(lines: lines, exitCode: nil, resumedAsNew: true)
        case .requested: nil
        case nil where ready:
            NativeStartProblem(kind: .stopped, exitCode: exitCode, signal: signal, lines: lastWords(before: exit))
        case nil: Self.classify(lines: lines, exitCode: exitCode, signal: signal, resumedAsNew: false)
        }
    }

    /// What a served pi wrote in the `wordsWindow` before `exit`, without stack frames: the newest
    /// `NativeStartProblem.maxLines` lines.
    private func lastWords(before exit: ContinuousClock.Instant) -> [String] {
        let since = exit - Self.wordsWindow
        let words = tail.filter { $0.at >= since && !Self.isStackFrame($0.line) }
        return words.suffix(NativeStartProblem.maxLines).map(\.line)
    }

    /// A frame of a stack trace: node's `at fn (file:1:2)`, `at file:1:2`, `at fn (<anonymous>)` or
    /// `at async Promise.all (index 0)`, or the native `3: 0x1008c6a30 node::Abort()`. A sentence that
    /// only starts with "at" is not one.
    static func isStackFrame(_ line: String) -> Bool {
        if line.hasPrefix("at ") {
            let frame = line.hasSuffix(")") ? line.dropLast() : line[...]
            if frame.hasSuffix("<anonymous>") { return true }
            if let open = frame.range(of: " (", options: .backwards), frame[open.upperBound...].hasPrefix("index ") { return true }
            let place = frame.split(separator: ":", omittingEmptySubsequences: false).suffix(3)
            return place.count == 3 && place.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }
        }
        let digits = line.prefix { $0 >= "0" && $0 <= "9" }
        return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(": 0x")
    }

    // MARK: Reading pi's words

    /// The cause pi's `lines` and exit give, with the newest `NativeStartProblem.maxLines` lines.
    static func classify(lines: [String], exitCode: Int32?, signal: Int32? = nil, resumedAsNew: Bool) -> NativeStartProblem {
        let kind: NativeStartProblem.Kind
        if resumedAsNew {
            kind = .resumedAsNew
        } else if lines.contains(where: { $0.hasPrefix(PiLaunch.folderMissingPrefix) }) {
            kind = .folderMissing
        } else if lines.contains(where: { $0.hasPrefix(PiLaunch.refusalPrefix) }) {
            // Shepherd's own refusal (`PiLaunch.refused`): its pi home and "your pi" overlap.
            kind = .homeUnsafe
        } else if lines.contains(where: { $0.contains("Failed to load extension") }) {
            // pi: main.js, a runtime diagnostic, which exits in every mode.
            kind = .extensionFailed
        } else if lines.contains(where: { $0.contains("No models available") || $0.contains("No API key found for") || Self.modelNotFound($0) }) {
            // pi: core/auth-guidance.js; and a model pi has no provider for (one an extension registers, switched
            // off), which the thread treats the same way: pick another model, or sign in.
            kind = .notSignedIn
        } else if exitCode == 127 || exitCode == 126 || lines.contains(where: { $0.contains("command not found:") }) {
            // The shell's own: nothing to run, or nothing it may run.
            kind = .engineMissing
        } else {
            kind = .exited
        }
        return NativeStartProblem(kind: kind, exitCode: exitCode, signal: signal, lines: Array(lines.suffix(NativeStartProblem.maxLines)))
    }

    /// pi's refusal of a model it doesn't know (pi: main.js): `Error: Model "cpa/x" not found. Use --list-models`.
    static func modelNotFound(_ line: String) -> Bool {
        line.contains("Model \"") && line.contains("\" not found")
    }

    /// pi's warning for a `--session-id` it found no session for (pi: main.js).
    static func startsNewConversation(_ line: String, id: String) -> Bool {
        line.contains("creating a new session") && line.contains("'\(id)'")
    }

    /// `line` without terminal escapes (pi colours its errors through chalk), carriage returns,
    /// or surrounding whitespace.
    static func plain(_ line: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = line.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar {
            case "\u{1B}":
                switch scalars.next() {
                case "[":
                    // CSI: parameters and intermediates, then one final byte in @…~.
                    while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
                case "]":
                    // OSC: up to BEL or ST (ESC \).
                    while let next = scalars.next() {
                        if next == "\u{07}" { break }
                        if next == "\u{1B}" { _ = scalars.next(); break }
                    }
                default:
                    // A two-byte escape: already consumed.
                    break
                }
            case "\r", "\u{07}":
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A session's process ended (`SessionServer.onSessionExited`).
public struct SessionExit: Equatable, Sendable {
    /// nil: a signal.
    public var code: Int32?
    /// An agent's pi, while its agent exists: its agent stays and waits (Retry). False for every
    /// other exit (a shell, or a pi whose agent was deleted), which retires what ran in the pane.
    public var keepsAgent: Bool
    /// Why it stopped; nil for a stop Shepherd asked for, and for every exit that keeps nothing.
    public var startProblem: NativeStartProblem?

    public init(code: Int32?, keepsAgent: Bool = false, startProblem: NativeStartProblem? = nil) {
        self.code = code
        self.keepsAgent = keepsAgent
        self.startProblem = startProblem
    }
}

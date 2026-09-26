import Foundation
import ShepherdProtocol

/// One agent pi's start, as the server sees it (DESIGN.md › Thread › Can't start): its last lines
/// on stderr until it serves its thread, and whether Shepherd stopped it. An exit before it
/// served, or one Shepherd asked for, keeps the agent, with the problem `problem(exitCode:)`
/// names; an exit after it served is a lost connection, as before.
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
    /// Its stderr so far, without colour codes or blank lines, at most `keptLines` of the newest.
    private(set) var lines: [String] = []

    /// Lines kept while pi starts; a problem carries the newest `NativeStartProblem.maxLines`.
    static let keptLines = 40

    init(resuming: String? = nil) {
        self.resuming = resuming
    }

    /// An exit now keeps the agent: pi never served, or Shepherd asked for it.
    var keepsAgent: Bool { !ready || stop != nil }

    /// pi serves its thread: what it said while starting is no longer needed, unless Shepherd is
    /// stopping it for what it said.
    mutating func served() {
        ready = true
        if stop == nil { lines = [] }
    }

    mutating func requestStop() {
        if stop == nil { stop = .requested }
    }

    /// One line pi wrote on stderr. True when it says pi is starting a new conversation under the
    /// id it was launched to resume: the caller stops pi before it writes anything. pi says so
    /// only while it starts, but its stderr and its first answers travel on separate pipes, so
    /// the line is honoured even once the thread serves.
    mutating func note(stderr line: String) -> Bool {
        let checksResume = stop == nil && resuming != nil
        guard !ready || checksResume else { return false }
        let plain = Self.plain(line)
        if !ready, !plain.isEmpty {
            lines.append(plain)
            if lines.count > Self.keptLines { lines.removeFirst(lines.count - Self.keptLines) }
        }
        guard checksResume, let resuming, Self.startsNewConversation(plain, id: resuming) else { return false }
        stop = .resumedAsNew
        if ready, !plain.isEmpty { lines = [plain] }
        return true
    }

    /// Why this pi's exit keeps its agent; nil for a stop Shepherd asked for, which is no problem.
    func problem(exitCode: Int32?) -> NativeStartProblem? {
        switch stop {
        case .resumedAsNew: Self.classify(lines: lines, exitCode: nil, resumedAsNew: true)
        case .requested: nil
        case nil: Self.classify(lines: lines, exitCode: exitCode, resumedAsNew: false)
        }
    }

    // MARK: Reading pi's words

    /// The cause pi's `lines` and exit give, with the newest `NativeStartProblem.maxLines` lines.
    static func classify(lines: [String], exitCode: Int32?, resumedAsNew: Bool) -> NativeStartProblem {
        let kind: NativeStartProblem.Kind
        if resumedAsNew {
            kind = .resumedAsNew
        } else if lines.contains(where: { $0.contains("Failed to load extension") }) {
            // pi: main.js, a runtime diagnostic, which exits in every mode.
            kind = .extensionFailed
        } else if lines.contains(where: { $0.contains("No models available") || $0.contains("No API key found for") }) {
            // pi: core/auth-guidance.js.
            kind = .notSignedIn
        } else if exitCode == 127 || exitCode == 126 || lines.contains(where: { $0.contains("command not found:") }) {
            // The shell's own: nothing to run, or nothing it may run.
            kind = .engineMissing
        } else {
            kind = .exited
        }
        return NativeStartProblem(kind: kind, exitCode: exitCode, lines: Array(lines.suffix(NativeStartProblem.maxLines)))
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
    /// An agent's pi that stopped before it served its thread, or that Shepherd stopped: its agent
    /// stays and waits (DESIGN.md › Thread › Can't start). False for every other exit, which
    /// retires what ran in the pane.
    public var keepsAgent: Bool
    /// Why a kept pi stopped; nil for a stop Shepherd asked for, and for every other exit.
    public var startProblem: NativeStartProblem?

    public init(code: Int32?, keepsAgent: Bool = false, startProblem: NativeStartProblem? = nil) {
        self.code = code
        self.keepsAgent = keepsAgent
        self.startProblem = startProblem
    }
}

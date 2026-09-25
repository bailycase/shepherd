import Foundation
import ShepherdProtocol

// The subagent tray (SubagentTray, Subagents, SubagentsDone, SubagentsQueue boards): the runs
// docked above the composer while they work, one row each, in the same card as Up next; and the
// two lines a parent turn keeps in the thread, "Started 3 subagents" where it spawned them and
// "3 subagents finished" where they finished. Pure and clock-free: times travel as
// milliseconds since the epoch and the views count from them.

// MARK: Rows

/// One run as its tray row draws it.
public struct NativeTrayRow: Equatable, Sendable, Identifiable {
    /// The row's words after the name, per state.
    public enum Line: Equatable, Sendable {
        /// A live run: what it is doing now ("Editing", "NativeThreadPresentation.swift").
        /// `live` while the call is in flight (the words shimmer).
        case working(verb: String, subject: String?, live: Bool)
        /// Queued, or paused before its next model request.
        case waiting(String)
        /// Waiting on you: its question.
        case asks(String)
        /// Finished: the first sentence of what it did.
        case result(String)
        /// Failed: why.
        case failed(String)
    }

    public var id: String
    public var runID: String
    public var name: String
    public var phase: NativeRunPhase
    public var line: Line
    /// Its combined diff so far, when it has one.
    public var added: Int?
    public var removed: Int?
    /// When its figure counts from (ms): the start of a live run, the question of a run that
    /// waits on you, else nil (no honest start).
    public var since: Double?
    /// When a finished run ended (ms): its figure is its duration.
    public var until: Double?

    /// "worker, Running, Editing NativeThreadPresentation.swift"
    public var accessibilityLabel: String {
        let words: String = switch line {
        case .working(let verb, let subject, _): [verb, subject].compactMap { $0 }.joined(separator: " ")
        case .waiting(let text), .result(let text), .failed(let text): text
        case .asks(let question): "asks: " + question
        }
        return [name, nativeRunPhaseLabel(phase), words].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// One tally part of the tray's header ("1 needs you"), with the phase that colors it (nil:
/// the quiet tertiary color).
public struct NativeTrayTally: Equatable, Sendable, Identifiable {
    public var id: String { text }
    public var text: String
    public var phase: NativeRunPhase?
}

/// The tray as it draws: its header and its rows.
public struct NativeSubagentTray: Equatable, Sendable {
    /// "3 subagents".
    public var title: String
    /// One cell per run, in row order.
    public var cells: [NativeRunPhase]
    /// "1 needs you · 1 running · 1 done", or "all done".
    public var tally: [NativeTrayTally]
    public var rows: [NativeTrayRow]

    /// Every run finished: the tray waits for your next message.
    public var allDone: Bool { !rows.contains { $0.phase.isLive } }

    /// Rows shown before "Show N more" (SubagentTray · 8 subagents).
    public static let shownRows = 4
    /// Header cells: a workflow of hundreds of runs shows its first ones (in row order, so the
    /// runs that need you and the live ones), and the tally counts the rest.
    public static let maxCells = 12

    public init(title: String, cells: [NativeRunPhase], tally: [NativeTrayTally], rows: [NativeTrayRow]) {
        self.title = title
        self.cells = cells
        self.tally = tally
        self.rows = rows
    }

    public init(_ runs: [ChildRun]) {
        let ordered = nativeTrayOrder(runs)
        let rows = ordered.map(nativeTrayRow)
        self.init(title: nativeCount(rows.count, "subagent"), cells: rows.prefix(Self.maxCells).map(\.phase),
                  tally: nativeTrayTally(rows.map(\.phase)), rows: rows)
    }
}

/// The tray's order: up to `shownRows` runs keep spawn order (the boards' worker · reviewer ·
/// tests); past that, the runs that need you come first, then live runs, then failed, then
/// done, each in spawn order, so the rows above "Show N more" are the ones to act on.
public func nativeTrayOrder(_ runs: [ChildRun]) -> [ChildRun] {
    let spawn = runs.sorted { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
    guard spawn.count > NativeSubagentTray.shownRows else { return spawn }
    func rank(_ phase: NativeRunPhase) -> Int {
        switch phase {
        case .needsYou: 0
        case .running, .queued, .paused: 1
        case .failed: 2
        case .done: 3
        }
    }
    return spawn.enumerated().sorted { (rank(nativeRunPhase($0.element)), $0.offset) < (rank(nativeRunPhase($1.element)), $1.offset) }
        .map(\.element)
}

/// "1 needs you · 3 running · 3 done · 1 failed" while any run is live or any failed; "all
/// done" once every run finished well.
public func nativeTrayTally(_ phases: [NativeRunPhase]) -> [NativeTrayTally] {
    guard !phases.isEmpty else { return [] }
    if !phases.contains(where: \.isLive), !phases.contains(.failed) { return [NativeTrayTally(text: "all done", phase: nil)] }
    let order: [NativeRunPhase] = [.needsYou, .running, .queued, .paused, .done, .failed]
    return order.compactMap { phase in
        let count = phases.count { $0 == phase }
        guard count > 0 else { return nil }
        let color: NativeRunPhase? = switch phase {
        case .needsYou, .running, .failed: phase
        default: nil
        }
        return NativeTrayTally(text: "\(count) \(phase.word)", phase: color)
    }
}

public func nativeTrayRow(_ run: ChildRun) -> NativeTrayRow {
    let phase = nativeRunPhase(run)
    let line: NativeTrayRow.Line
    var since = run.startedAt
    var until: Double?
    switch phase {
    case .running:
        let now = nativeRunNow(run)
        line = .working(verb: now.verb, subject: now.subject, live: now.live)
    case .queued:
        line = .waiting("Waiting to start")
        since = nil
    case .paused:
        line = .waiting("Paused before its next model request")
    case .needsYou:
        let question = run.question?.text ?? run.attentionText ?? ""
        line = .asks(question.isEmpty ? "your answer" : nativeQuestionLine(question))
        since = nativeRunAskedAt(run)
    case .done:
        let summary = nativeRunSummaryLine(run)
        line = .result(summary.isEmpty ? "Finished" : summary)
        until = run.endedAt
    case .failed:
        line = .failed(nativeTrayFailure(run))
        until = run.endedAt
    }
    let added = run.result?.added ?? run.files.map { $0.reduce(0) { $0 + $1.added } }
    let removed = run.result?.removed ?? run.files.map { $0.reduce(0) { $0 + $1.removed } }
    let hasDiff = (added ?? 0) + (removed ?? 0) > 0
    return NativeTrayRow(id: run.id, runID: run.runID, name: nativeRunNames(run).name, phase: phase, line: line,
                         added: hasDiff ? added ?? 0 : nil, removed: hasDiff ? removed ?? 0 : nil,
                         since: until == nil ? since : run.startedAt, until: until)
}

/// Why a run failed, without the exit code the reason leads with ("exit 1 · context limit
/// reached after 41 turns" reads "context limit reached after 41 turns").
func nativeTrayFailure(_ run: ChildRun) -> String {
    let reason = run.exitReason ?? (run.state == "failed" ? "failed" : run.state)
    let parts = reason.components(separatedBy: " · ")
    if parts.count > 1, let first = parts.first, first.hasPrefix("exit "), Int(first.dropFirst(5)) != nil {
        return parts.dropFirst().joined(separator: " · ")
    }
    return reason
}

/// What a live run is doing: its call in flight in the present tense ("Editing" and the file
/// name, "Running tests" and the command), else its last call in the past ("Edited"), else
/// the tool it reports, else "Starting".
public func nativeRunNow(_ run: ChildRun) -> (verb: String, subject: String?, live: Bool) {
    if let last = run.lastActivity {
        let (verb, subject) = nativeRunCallWords(tool: last.tool, preview: last.preview, running: last.isRunning)
        return (verb, subject, last.isRunning)
    }
    if let tool = run.currentTool {
        let (verb, subject) = nativeRunCallWords(tool: tool, preview: nil, running: true)
        return (verb, subject, true)
    }
    return ("Starting", nil, true)
}

/// A call's words: the verb and what it acts on (a file name, or the command that decided a
/// shell call's kind).
func nativeRunCallWords(tool: String, preview: String?, running: Bool) -> (verb: String, subject: String?) {
    let preview = preview?.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = preview.flatMap { $0.isEmpty ? nil : nativeRunFileName($0) }
    switch tool {
    case "read": return (running ? "Reading" : "Read", path)
    case "grep", "find", "glob": return (running ? "Searching" : "Searched", preview.flatMap { $0.isEmpty ? nil : $0 })
    case "ls": return (running ? "Listing" : "Listed", path)
    case "edit": return (running ? "Editing" : "Edited", path)
    case "write": return (running ? "Writing" : "Wrote", path)
    case "bash":
        guard let command = preview, !command.isEmpty else { return (running ? "Running a command" : "Ran a command", nil) }
        let head = nativeCommandHead(command)
        let verb = switch nativeCommandClasses(command).first ?? .other {
        case .tests: running ? "Running tests" : "Ran tests"
        case .build: running ? "Building" : "Built"
        case .commit: running ? "Committing" : "Committed"
        case .push: running ? "Pushing" : "Pushed"
        case .other: running ? "Running" : "Ran"
        }
        return (verb, head)
    case "shepherd_child_start": return (running ? "Starting a subagent" : "Started a subagent", nil)
    default: return (running ? "Running" : "Ran", tool)
    }
}

// MARK: Which runs the tray shows

/// The runs the tray shows, or nil when it shows none: the newest spawn group (with any run
/// still live from an earlier one) while any of them is live, and, once all have finished,
/// until your next message (SubagentsDone: "the tray stays until your next message").
/// `lastUserMessageAt` is when you last sent a message into the thread (ms).
public func nativeTrayRuns(_ runs: [ChildRun], placements: [String: NativeSubagentPlacement], turnOrder: [String],
                           lastUserMessageAt: Double?) -> [ChildRun]? {
    let current = nativeRunSections(runs, placements: placements, turnOrder: turnOrder).current
    guard !current.isEmpty else { return nil }
    if current.contains(where: { nativeRunPhase($0).isLive }) { return current }
    let finished = current.compactMap { $0.endedAt ?? $0.startedAt }.max() ?? 0
    if let sent = lastUserMessageAt, sent > finished { return nil }
    return current
}

// MARK: The thread's record

/// One line the thread keeps for a turn's subagents: "Started 3 subagents" with their names, or
/// "3 subagents finished" with "45m · 7 files · +318 −64".
public struct NativeSubagentRecordLine: Hashable, Sendable {
    public var title: String
    public var meta: String

    public init(title: String, meta: String) {
        self.title = title
        self.meta = meta
    }
}

/// A turn's record of its subagents (SubagentRecord): the line where they started, and once
/// every run finished, the line where they did.
public struct NativeSubagentRecord: Hashable, Sendable {
    public var started: NativeSubagentRecordLine
    public var finished: NativeSubagentRecordLine?
    /// When the last run ended (ms): the finished line sits before whatever came after it.
    public var finishedAt: Double?
    /// The run the lines open in the inspector: the first spawned.
    public var firstRunID: String?

    public init(started: NativeSubagentRecordLine, finished: NativeSubagentRecordLine? = nil, finishedAt: Double? = nil,
                firstRunID: String? = nil) {
        self.started = started
        self.finished = finished
        self.finishedAt = finishedAt
        self.firstRunID = firstRunID
    }

    /// Names shown on the started line before "+N more".
    public static let namedRuns = 6

    public init?(_ runs: [ChildRun]) {
        guard !runs.isEmpty else { return nil }
        let ordered = runs.sorted { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
        let names = ordered.map { nativeRunNames($0).name }
        var named = Array(names.prefix(Self.namedRuns))
        if names.count > Self.namedRuns { named.append("+\(names.count - Self.namedRuns) more") }
        started = NativeSubagentRecordLine(title: "Started " + nativeCount(ordered.count, "subagent"), meta: named.joined(separator: " · "))
        firstRunID = ordered.first?.runID
        guard nativeSubagentGroupIsTerminal(ordered) else { return }
        let first = ordered.compactMap(\.startedAt).min()
        let last = ordered.compactMap(\.endedAt).max()
        var meta: [String] = []
        if let first, let last { meta.append(nativeRunDurationShort(max(0, last - first) / 1000)) }
        let failed = ordered.count { nativeRunPhase($0) == .failed }
        if failed > 0 { meta.append("\(failed) failed") }
        // Paths a run names count once across runs; a run that names none counts its own total.
        let paths = Set(ordered.flatMap { $0.files?.map(\.path) ?? [] })
        let files = paths.count + ordered.filter { $0.files?.isEmpty != false }.compactMap { $0.result?.files }.reduce(0, +)
        if files > 0 { meta.append(nativeCount(files, "file")) }
        let added = ordered.map { $0.result?.added ?? $0.files?.reduce(0) { $0 + $1.added } ?? 0 }.reduce(0, +)
        let removed = ordered.map { $0.result?.removed ?? $0.files?.reduce(0) { $0 + $1.removed } ?? 0 }.reduce(0, +)
        if added + removed > 0 { meta.append("+\(added) −\(removed)") }
        finished = NativeSubagentRecordLine(title: nativeCount(ordered.count, "subagent") + " finished", meta: meta.joined(separator: " · "))
        finishedAt = last
    }
}

// MARK: Answering from the tray

/// A run's question as the composer's question panel shows it once its row's Answer is tapped
/// (touch): the answers it offered to choose from, else a reply. nil once it no longer asks.
public func nativeSubagentQuestionDialog(_ run: ChildRun) -> NativeThreadDialog? {
    guard nativeRunPhase(run) == .needsYou else { return nil }
    let text = run.question?.text ?? run.attentionText ?? ""
    let options = run.question?.options ?? []
    return NativeThreadDialog(id: "subagent:" + run.id, kind: options.isEmpty ? .input : .select, title: text.isEmpty ? "Waiting on your answer" : text,
                              options: options.isEmpty ? nil : options, placeholder: "Reply to \(nativeRunNames(run).name)…")
}

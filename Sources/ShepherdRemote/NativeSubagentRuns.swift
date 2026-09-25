import Foundation
import ShepherdProtocol

// Subagent runs as the touch client draws them (MobileSubagents, MobileSubagent, MobileSteer,
// iPadSteer and iPadSubagents boards): each run's values, the thread's list of runs, the
// controls a run offers, and the commands they send. Pure and clock-free: times travel as
// milliseconds since the epoch and the views count from them.

// MARK: Phase

/// A run's state: the four card states, with the two ways a live run waits (queued, or paused
/// before its next model request) told apart.
public enum NativeRunPhase: String, CaseIterable, Equatable, Sendable {
    case running, queued, paused, needsYou, done, failed

    /// Still going: running, waiting to start or to continue, or waiting on your answer.
    public var isLive: Bool {
        switch self {
        case .running, .queued, .paused, .needsYou: true
        case .done, .failed: false
        }
    }

    /// The tally's word ("2 running · 1 needs you").
    public var word: String {
        switch self {
        case .running: "running"
        case .queued: "queued"
        case .paused: "paused"
        case .needsYou: "needs you"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

public func nativeRunPhase(_ run: ChildRun) -> NativeRunPhase {
    switch nativeSubagentState(run) {
    case .needsYou: .needsYou
    case .done: .done
    case .failed: .failed
    case .running: run.paused == true ? .paused : run.state == "queued" ? .queued : .running
    }
}

// MARK: Names and tags

/// A run's name and role tag. A native child's label is "role: task", so it is named by its
/// role and no tag repeats it; a workflow lane is named by its key and tagged with its role.
public func nativeRunNames(_ run: ChildRun) -> (name: String, role: String?) {
    guard let role = run.role, !role.isEmpty else { return (run.label, nil) }
    if run.label == role || run.label.hasPrefix("\(role): ") { return (role, nil) }
    return (run.label, role)
}

/// "claude-sonnet" from "anthropic/claude-sonnet".
public func nativeModelTag(_ model: String) -> String {
    model.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? model
}

/// A path's file name ("Sources/A/B.swift" → "B.swift"); anything else as is.
func nativeRunFileName(_ preview: String) -> String {
    guard preview.contains("/"), !preview.contains(where: \.isWhitespace),
          let name = preview.split(separator: "/").last, !name.isEmpty else { return preview }
    return String(name)
}

// MARK: One run

/// Everything the touch client shows for one run, derived once per change.
public struct NativeRunSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var runID: String
    public var name: String
    /// The role, when it differs from the name.
    public var role: String?
    /// "background · fable-5-1": the role tag, how it runs, and its model.
    public var tags: String?
    public var phase: NativeRunPhase
    /// One line: what it is doing, why it waits, what it did, or why it failed.
    public var detail: String
    /// The group card's shorter line: "step 1 of 3 · edit ThreadView.swift", "needs you: rename
    /// or replace?", "14 of 14 pass".
    public var compactDetail: String
    /// "step 1 of 3", while live.
    public var step: String?
    /// Context window used, 0…1, while it runs.
    public var progress: Double?
    /// "922k", tokens used so far.
    public var tokens: String?
    /// Its question and the answers it offered (the first is the recommended one), while it
    /// needs you.
    public var question: String?
    public var options: [String]
    /// Milliseconds since the epoch.
    public var startedAt: Double?
    /// Set once finished.
    public var endedAt: Double?
    /// When it began waiting on you: the time of its `shepherd_parent_message` call. nil when
    /// nothing gives an honest start.
    public var askedAt: Double?
    /// Its combined diff, once it has one.
    public var added: Int?
    public var removed: Int?
    /// A finished run's "5 files · 41m".
    public var meta: String?
    /// The delegated task.
    public var goal: String
    /// A finished run's result (its summary or output), or why it failed.
    public var result: String?

    /// Whole seconds from start to end, once finished.
    public var duration: Double? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, (endedAt - startedAt) / 1000)
    }

    /// "worker, background · fable-5-1, Running, step 1 of 3, edit ThreadView.swift"
    public var accessibilityLabel: String {
        [name, tags, nativeRunPhaseLabel(phase), step, detail, meta].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The state's word for headers and VoiceOver: "Running", "Needs you", "Paused".
public func nativeRunPhaseLabel(_ phase: NativeRunPhase) -> String {
    switch phase {
    case .running: "Running"
    case .queued: "Queued"
    case .paused: "Paused"
    case .needsYou: "Needs you"
    case .done: "Done"
    case .failed: "Failed"
    }
}

public func nativeRunSummary(_ run: ChildRun) -> NativeRunSummary {
    let (name, role) = nativeRunNames(run)
    let phase = nativeRunPhase(run)
    let tags = [role, run.context, run.model.map(nativeModelTag)].compactMap { $0 }.filter { !$0.isEmpty }
    let step = phase.isLive ? run.step.map { "step \($0.index) of \($0.total)" } : nil
    var summary = NativeRunSummary(
        id: run.id, runID: run.runID, name: name, role: role, tags: tags.isEmpty ? nil : tags.joined(separator: " · "),
        phase: phase, detail: "", compactDetail: "", step: step, tokens: run.tokens.flatMap { $0 > 0 ? nativeCompactTokens($0) : nil },
        options: [], startedAt: run.startedAt, endedAt: run.isTerminal ? run.endedAt : nil,
        goal: run.task ?? run.label)
    let added = run.result?.added ?? run.files.map { $0.reduce(0) { $0 + $1.added } }
    let removed = run.result?.removed ?? run.files.map { $0.reduce(0) { $0 + $1.removed } }
    if let added, let removed, added + removed > 0 {
        summary.added = added
        summary.removed = removed
    }
    switch phase {
    case .running:
        summary.detail = nativeRunActivity(run)
        summary.compactDetail = [step, summary.detail].compactMap { $0 }.joined(separator: " · ")
        summary.progress = run.contextPercent.map { min(1, max(0, $0 / 100)) }
    case .queued:
        summary.detail = "waiting to start"
        summary.compactDetail = summary.detail
    case .paused:
        summary.detail = "paused before its next model request"
        summary.compactDetail = "paused"
    case .needsYou:
        let question = run.question?.text ?? run.attentionText ?? ""
        summary.detail = "waiting on your answer"
        summary.question = question.isEmpty ? nil : question
        summary.options = run.question?.options ?? []
        summary.askedAt = nativeRunAskedAt(run)
        summary.compactDetail = question.isEmpty ? "needs you" : "needs you: " + nativeQuestionLine(question)
    case .done:
        let line = nativeRunSummaryLine(run)
        summary.detail = line.isEmpty ? "finished" : line
        summary.compactDetail = summary.detail
        let text = run.summary ?? run.output
        summary.result = text?.isEmpty == false ? text : nil
    case .failed:
        summary.detail = run.exitReason ?? run.state
        summary.compactDetail = summary.detail
        summary.result = run.exitReason ?? run.summary
    }
    if !phase.isLive {
        let files = run.result?.files ?? run.files?.count ?? 0
        let meta = [files > 0 ? nativeCount(files, "file") : nil, summary.duration.map { nativeRunDurationShort($0) }].compactMap { $0 }
        summary.meta = meta.isEmpty ? nil : meta.joined(separator: " · ")
    }
    return summary
}

/// What a running child is doing: its last call with a path shortened to the file name ("edit
/// ThreadView.swift"), else the tool in flight.
public func nativeRunActivity(_ run: ChildRun) -> String {
    if let last = run.lastActivity {
        guard let preview = last.preview, !preview.isEmpty else { return last.tool }
        return "\(last.tool) \(nativeRunFileName(preview))"
    }
    return run.currentTool ?? "working"
}

/// What moves at the end of a live run's transcript (LiveText): the call in flight, as its own
/// live line, or "Thinking…" between tools. Nothing while the run asks, once it has ended, or
/// with a pause requested and no call left to finish (waiting isn't working).
public enum NativeRunLive: Equatable, Sendable {
    case call(NativeActivityBurst)
    case thinking
}

/// A run's live tail. A transcript reads the child's session file, which holds only finished
/// calls, so the call in flight is built from what the run reports: its tool, and the command
/// or path of its running `lastActivity` (an older host reports only the tool), timed from when
/// it began. It has no output to tail.
public func nativeRunLive(_ run: ChildRun) -> NativeRunLive? {
    guard !run.isTerminal, !run.needsAttention else { return nil }
    guard let tool = run.currentTool else { return run.paused == true ? nil : .thinking }
    let activity = run.lastActivity.flatMap { $0.isRunning && $0.tool == tool ? $0 : nil }
    let preview = activity?.preview.flatMap { $0.isEmpty ? nil : $0 }
    let key = ["bash", "powershell"].contains(tool) ? "command" : "path"
    let arguments = preview.flatMap { try? JSONSerialization.data(withJSONObject: [key: $0]) }.map { String(decoding: $0, as: UTF8.self) }
    var call = NativeActivityCall(NativeThreadMessage(
        entryID: "live:" + run.id, role: "toolResult", blocks: [], toolName: tool, toolCallID: "live:" + run.id,
        argumentsText: arguments, status: "running", startedAt: activity?.at))
    if call.detail.isEmpty, let preview { call.detail = preview }
    return .call(nativeActivityBurst([call]))
}

/// A native child asks through `shepherd_parent_message`, so that call's time is when it began
/// waiting; anything else gives no honest start.
public func nativeRunAskedAt(_ run: ChildRun) -> Double? {
    guard let last = run.lastActivity, last.tool == "shepherd_parent_message" else { return nil }
    return last.at
}

/// A finished run's first sentence (of its summary, else its output), without inline Markdown
/// markers.
public func nativeRunSummaryLine(_ run: ChildRun, limit: Int = 160) -> String {
    let sentence = nativeFirstSentence(run.summary ?? run.output ?? "", limit: limit)
    guard let parsed = try? AttributedString(markdown: sentence, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
        return sentence
    }
    let plain = String(parsed.characters)
    return plain.hasSuffix(".") && !plain.hasSuffix("..") ? String(plain.dropLast()) : plain
}

/// The line of a question that asks: its last sentence ending in "?", else its first sentence,
/// without inline Markdown markers.
public func nativeQuestionLine(_ text: String) -> String {
    let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var sentences: [Substring] = []
    var start = flat.startIndex
    var cursor = flat.startIndex
    while let end = flat[cursor...].firstIndex(where: { ".!?".contains($0) }) {
        let after = flat.index(after: end)
        if after == flat.endIndex || flat[after].isWhitespace {
            sentences.append(flat[start...end])
            start = after
        }
        cursor = after
    }
    if start < flat.endIndex { sentences.append(flat[start...]) }
    let line = sentences.last { $0.hasSuffix("?") }.map(String.init) ?? nativeFirstSentence(flat, limit: 120)
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let parsed = try? AttributedString(markdown: trimmed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
        return trimmed
    }
    return String(parsed.characters)
}

/// "48s", "37m", "2h": a run's duration in a row.
public func nativeRunDurationShort(_ seconds: Double) -> String {
    nativeSubagentShortDuration(seconds)
}

// MARK: The thread's runs

/// The subagents screen's two sections: the runs of the newest turn that spawned any (plus any
/// run still live from an earlier turn), in spawn order; and every other run, newest first.
public struct NativeRunSections: Equatable, Sendable {
    public var current: [ChildRun]
    public var earlier: [ChildRun]

    public init(current: [ChildRun] = [], earlier: [ChildRun] = []) {
        self.current = current
        self.earlier = earlier
    }

    public var isEmpty: Bool { current.isEmpty && earlier.isEmpty }
    public var all: [ChildRun] { current + earlier }
}

/// `placements` are the store's (by turn id) and `turnOrder` the thread's turn ids in order.
public func nativeRunSections(_ runs: [ChildRun], placements: [String: NativeSubagentPlacement], turnOrder: [String]) -> NativeRunSections {
    let spawnOrder: (ChildRun, ChildRun) -> Bool = { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
    guard let latest = turnOrder.last(where: { placements[$0]?.isEmpty == false }), let placed = placements[latest] else {
        return NativeRunSections(current: runs.sorted(by: spawnOrder))
    }
    let latestIDs = Set(placed.all.map(\.id))
    let current = runs.filter { latestIDs.contains($0.id) || nativeRunPhase($0).isLive }
    let currentIDs = Set(current.map(\.id))
    let earlier = runs.filter { !currentIDs.contains($0.id) }
        .sorted { ($0.endedAt ?? $0.startedAt ?? 0, $0.id) > ($1.endedAt ?? $1.startedAt ?? 0, $1.id) }
    return NativeRunSections(current: current.sorted(by: spawnOrder), earlier: earlier)
}

/// The header's line over a set of runs: the live phases while any run is live ("1 running · 1
/// needs you"), else how they ended ("all done", "2 done · 1 failed"). `phase` colors it:
/// running first, then needs you, then queued or paused, then failed, else done.
public func nativeRunTally(_ runs: [ChildRun]) -> (text: String, phase: NativeRunPhase)? {
    guard !runs.isEmpty else { return nil }
    let phases = runs.map(nativeRunPhase)
    let live = phases.contains(where: \.isLive)
    let order: [NativeRunPhase] = live ? [.running, .queued, .paused, .needsYou] : [.done, .failed]
    let parts = order.compactMap { phase -> String? in
        let count = phases.count { $0 == phase }
        return count > 0 ? "\(count) \(phase.word)" : nil
    }
    let text = !live && !phases.contains(.failed) ? "all done" : parts.joined(separator: " · ")
    let lead = [NativeRunPhase.running, .needsYou, .queued, .paused, .failed].first(where: phases.contains) ?? .done
    return (text, lead)
}

/// "Waiting on worker and reviewer": the live runs the turn waits for; nil when none is live.
public func nativeRunWaitingLabel(_ runs: [ChildRun]) -> String? {
    let live = runs.filter { !$0.isTerminal || $0.needsAttention }.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    guard !live.isEmpty else { return nil }
    if live.count > 3 { return "Waiting on \(nativeCount(live.count, "subagent"))" }
    return "Waiting on " + nativeJoinedList(live.map { nativeRunNames($0).name })
}

/// A finished group's status: "all done · 45m" or "2 done · 1 failed · 45m", from its first
/// start to its last end. nil while any run is live.
public func nativeRunGroupStatus(_ runs: [ChildRun]) -> String? {
    guard nativeSubagentGroupIsTerminal(runs), let tally = nativeRunTally(runs) else { return nil }
    var parts = [tally.text]
    if let first = runs.compactMap(\.startedAt).min(), let last = runs.compactMap(\.endedAt).max() {
        parts.append(nativeRunDurationShort(max(0, last - first) / 1000))
    }
    return parts.joined(separator: " · ")
}

/// The run header's mono line: a live run's model, thinking, turns and tokens; a finished run's
/// model and turns, then "done 11:02" (the accent, in the state's color).
public func nativeRunInspectorMeta(_ run: ChildRun, timeZone: TimeZone = .current) -> (meta: String, accent: String?) {
    var parts: [String] = []
    if let model = run.model { parts.append(nativeModelTag(model)) }
    if !run.isTerminal, let thinking = run.thinking, thinking != "off" { parts.append("thinking \(thinking)") }
    if let turns = run.turns { parts.append(nativeCount(turns, "turn")) }
    if !run.isTerminal, let tokens = run.tokens { parts.append("\(nativeCompactTokens(tokens)) tok") }
    guard run.isTerminal else { return (parts.joined(separator: " · "), nil) }
    let word = run.state == "complete" ? "done" : run.state
    return (parts.joined(separator: " · "), run.endedAt.map { "\(word) \(nativeClockText($0, meridiem: false, timeZone: timeZone))" } ?? word)
}

// MARK: Controls and commands

/// What a run offers besides steering: Pause or Continue and Stop while it is live, Re-run once
/// it has finished.
public enum NativeRunControl: String, CaseIterable, Equatable, Sendable {
    case pause, `continue`, stop, rerun

    public var action: NativeSubagentAction {
        switch self {
        case .pause: .pause
        case .continue: .continue
        case .stop: .cancel
        case .rerun: .resume
        }
    }

    public var title: String {
        switch self {
        case .pause: "Pause"
        case .continue: "Continue"
        case .stop: "Stop"
        case .rerun: "Re-run"
        }
    }
}

/// A live run pauses (or continues) and stops; one waiting on you only stops; a finished run
/// re-runs.
public func nativeRunControls(_ run: ChildRun) -> [NativeRunControl] {
    switch nativeRunPhase(run) {
    case .running, .queued: [.pause, .stop]
    case .paused: [.continue, .stop]
    case .needsYou: [.stop]
    case .done, .failed: [.rerun]
    }
}

/// Whether a run takes a steer: only while it is live. A finished run is read-only.
public func nativeRunAcceptsSteer(_ run: ChildRun) -> Bool {
    nativeRunPhase(run).isLive
}

/// One `subagentCommand`'s arguments: a steer or an answer reaches only that child, delivered
/// before its next turn; a control carries no text.
public struct NativeRunCommand: Equatable, Sendable {
    public var action: NativeSubagentAction
    public var text: String?
    public var mode: NativeThreadDelivery?

    public init(_ control: NativeRunControl) {
        action = control.action
    }

    private init(message: String) {
        action = .message
        text = message
        mode = .steer
    }

    /// A steer typed for the child; nil when there is nothing to send.
    public static func steer(_ draft: String) -> NativeRunCommand? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : NativeRunCommand(message: text)
    }

    /// An answer to the child's question: one of its options, or a reply typed for it.
    public static func answer(_ reply: String) -> NativeRunCommand? {
        steer(reply)
    }
}

// MARK: Transcript

/// Keeps older transcript pages the reader already loaded: the fresh newest page replaces
/// everything from its first entry on. With no overlap the page replaces the whole transcript
/// (`replaced`), and its cursor and count then stand.
public func nativeTranscriptSplice(_ current: [NativeThreadMessage], newest page: NativeSubagentTranscript) -> (messages: [NativeThreadMessage], replaced: Bool) {
    if let first = page.messages.first, let overlap = current.firstIndex(where: { $0.entryID == first.entryID }) {
        return (Array(current[..<overlap]) + page.messages, false)
    }
    return (page.messages, true)
}

/// A transcript's user turn that the user wrote (steers and answers sent from the card or the
/// inspector) rather than the parent, so it is not captioned "from parent". The host marks each
/// such message; an older host marks none.
public func nativeTranscriptTurnIsTheUsers(_ messages: [NativeThreadMessage]) -> Bool {
    !messages.isEmpty && messages.allSatisfy { $0.origin == .user }
}

/// An older page in front of what is loaded, without entries already shown.
public func nativeTranscriptPrepend(_ current: [NativeThreadMessage], older page: NativeSubagentTranscript) -> [NativeThreadMessage] {
    let ids = Set(current.map(\.entryID))
    return page.messages.filter { !ids.contains($0.entryID) } + current
}

/// Plain text of a transcript for Copy: each message's text with its role, and tool output
/// under the tool's name.
public func nativeTranscriptText(_ messages: [NativeThreadMessage]) -> String {
    messages.compactMap { message -> String? in
        if let tool = message.toolName { return "[\(tool)] " + message.blocks.map(\.text).joined(separator: "\n") }
        let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        return text.isEmpty ? nil : "\(message.role): \(text)"
    }.joined(separator: "\n\n")
}

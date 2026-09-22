import Foundation
import ShepherdProtocol

// Pure derivations shared by the desktop and iOS native views. Nothing here
// touches the store, the protocol, or the extension: it only reads a snapshot's
// messages and turns them into row/pill/duration text.

/// One tool call as a scannable row: glyph · name · preview · result · duration.
public struct NativeToolRow: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, done, failed }
    public enum Tone: Equatable, Sendable { case success, danger, muted }
    public struct Result: Equatable, Sendable {
        public var text: String
        public var tone: Tone
        public init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }
    }

    public var name: String
    public var state: State
    /// Primary preview in the text color: a path, a command, a quoted pattern.
    public var preview: String
    /// Muted tail after the preview: `:237–396` for a read range, ` in Sources/` for grep.
    public var previewSuffix: String?
    public var diff: NativeDiffStat?
    public var results: [Result]
    /// Saved output (text blocks joined). Empty means the row cannot expand.
    public var output: String
    /// Raw JSON arguments for the ⌥-click "Show call" popover; never shown inline.
    public var arguments: String?
    public var truncated: Bool
    /// Milliseconds since epoch: when the call began, and when its result landed.
    public var startedAt: Double?
    public var endedAt: Double?
    /// The file an edit or write touched, for the thread's "review ›" link.
    public var reviewPath: String?

    /// Spec §5: 1 decimal under a minute, then "48s"-style whole units; live while running.
    /// Nil when the host reported no start time.
    public func duration(now: Date) -> (text: String, live: Bool)? {
        guard let startedAt else { return nil }
        if state == .running {
            return (nativeDurationText(now.timeIntervalSince1970 - startedAt / 1000, live: true), true)
        }
        guard let endedAt, endedAt >= startedAt else { return nil }
        return (nativeDurationText((endedAt - startedAt) / 1000), false)
    }

    public var expandable: Bool { !output.isEmpty }

    /// "read, DesktopNativeThreadView.swift, 160 lines, done"
    public var accessibilityLabel: String {
        var parts = [name, preview + (previewSuffix ?? "")]
        if let diff { parts.append(nativeDiffText(added: diff.added, removed: diff.removed)) }
        parts += results.map(\.text)
        switch state {
        case .running: parts.append("running")
        case .done: parts.append("done")
        case .failed: parts.append("failed")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

public struct NativeDiffStat: Equatable, Sendable {
    public var added: Int
    public var removed: Int
    public var blocks: Int
    public init(added: Int, removed: Int, blocks: Int) {
        self.added = added; self.removed = removed; self.blocks = blocks
    }

    /// Line counts per edit as a multiset difference: lines that only disappear
    /// count as removed, lines that only appear count as added. Moved lines cancel.
    public init(edits: [(old: String, new: String)]) {
        var added = 0, removed = 0
        for edit in edits {
            var counts: [Substring: Int] = [:]
            func lines(_ text: String) -> [Substring] { text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false) }
            for line in lines(edit.old) { counts[line, default: 0] += 1 }
            for line in lines(edit.new) { counts[line, default: 0] -= 1 }
            for value in counts.values { if value > 0 { removed += value } else { added -= value } }
        }
        self.init(added: added, removed: removed, blocks: edits.count)
    }
}

public extension NativeToolRow {
    init(_ message: NativeThreadMessage) {
        let name = message.toolName ?? "result"
        let args = message.argumentsText.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let output = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        let failed = message.isError == true
        let state: State = failed ? .failed : message.status == "running" || message.status == "streaming" ? .running : .done
        func string(_ key: String) -> String? { (args?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ key: String) -> Int? { (args?[key] as? NSNumber)?.intValue }
        let firstLine = output.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { String($0.prefix(120)) } ?? ""
        let lineCount = output.isEmpty ? 0 : output.split(separator: "\n", omittingEmptySubsequences: false).count

        var preview = ""
        var suffix: String?
        var diff: NativeDiffStat?
        var results: [Result] = []
        switch name {
        case "read", "write":
            preview = string("path") ?? firstLine
            if name == "read", let offset = int("offset") {
                suffix = int("limit").map { ":\(offset)–\(offset + $0 - 1)" } ?? ":\(offset)–"
            }
            if name == "read", !failed, lineCount > 0 { results.append(Result("\(lineCount) line\(lineCount == 1 ? "" : "s")", tone: .muted)) }
        case "edit":
            preview = string("path") ?? firstLine
            var edits: [(old: String, new: String)] = []
            if let list = args?["edits"] as? [[String: Any]] {
                edits = list.compactMap { edit in
                    guard let old = edit["oldText"] as? String, let new = edit["newText"] as? String else { return nil }
                    return (old, new)
                }
            } else if let old = string("oldText"), let new = args?["newText"] as? String {
                edits = [(old, new)]
            }
            if !edits.isEmpty, !failed {
                let stat = NativeDiffStat(edits: edits)
                diff = stat
                results.append(Result("\(stat.blocks) block\(stat.blocks == 1 ? "" : "s")", tone: .muted))
            }
        case "bash", "powershell":
            preview = string("command").flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) } ?? firstLine
            if failed {
                if let code = capture(#"Command exited with code (\d+)"#, in: output) {
                    results.append(Result("exit \(code)", tone: .danger))
                } else {
                    results.append(Result("failed", tone: .danger))
                }
            } else if output.contains("BUILD SUCCEEDED") {
                results.append(Result("BUILD SUCCEEDED", tone: .success))
            } else if let count = capture(#"(\d+) (?:tests? |checks? )?passed"#, in: output) {
                results.append(Result("\(count) passed", tone: .success))
            } else if let count = capture(#"(\d+) files? changed"#, in: output) {
                results.append(Result("\(count) file\(count == "1" ? "" : "s") changed", tone: .success))
            }
        case "grep":
            preview = string("pattern").map { "\"\($0)\"" } ?? firstLine
            suffix = " in " + (string("path") ?? ".")
            if !failed {
                let count = output.hasPrefix("No matches") ? 0 : lineCount
                results.append(Result("\(count) match\(count == 1 ? "" : "es")", tone: .muted))
            }
        case "find", "glob":
            preview = string("pattern") ?? firstLine
            suffix = " in " + (string("path") ?? ".")
            if !failed, lineCount > 0 { results.append(Result("\(lineCount) file\(lineCount == 1 ? "" : "s")", tone: .muted)) }
        case "ls":
            preview = string("path") ?? "."
        case "shepherd_parent_message":
            // The child's message to its parent, not the JSON receipt.
            preview = string("message") ?? firstLine
            if args?["needsReply"] as? Bool == true { results.append(Result("asked", tone: .muted)) }
        case "subagent":
            // pi-subagents: the output is launch boilerplate ("Run fan-out: 0/32 used…"); the
            // agent and its task say what the call did.
            let task = string("task").flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) }
            if let agent = string("agent") {
                preview = task.map { "\(agent) · \($0)" } ?? agent
            } else if args?["workflowScript"] != nil {
                preview = "workflow"
            } else {
                preview = string("action") ?? firstLine
            }
        default:
            // Spec §5 says unknown tools show the first output line; we prefer an obvious action
            // field first (a URL beats "<html>") and fall back to output. The 120-char cap is the spec's.
            preview = ["command", "path", "query", "url", "pattern"].compactMap(string).first ?? firstLine
        }
        if failed, results.isEmpty { results.append(Result("failed", tone: .danger)) }
        // Internal tool ids read as noise when truncated ("shep…sage"); name them for people.
        let display = name == "shepherd_parent_message" ? "to parent" : name
        self.init(name: display, state: state, preview: String(preview.prefix(120)), previewSuffix: suffix, diff: diff,
                  results: results, output: output, arguments: message.argumentsText, truncated: message.truncated,
                  startedAt: message.startedAt, endedAt: state == .running ? nil : message.timestamp,
                  reviewPath: (name == "edit" || name == "write") && !failed ? string("path") : nil)
    }
}

/// Files the agent's current turn has edited or written (as the tool calls named them), for
/// the review pane's "being edited" dots. Empty when the agent is not running.
public func nativeTouchedPaths(_ messages: [NativeThreadMessage], running: Bool) -> Set<String> {
    guard running else { return [] }
    let turn = messages.lastIndex { $0.role == "user" }.map { messages.index(after: $0) } ?? messages.startIndex
    var paths: Set<String> = []
    for message in messages[turn...] where message.toolName == "edit" || message.toolName == "write" {
        guard let data = message.argumentsText?.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty else { continue }
        paths.insert(path)
    }
    return paths
}

/// "+58 −41" with a true minus sign: the one spelling of a DiffStat as text.
public func nativeDiffText(added: Int, removed: Int) -> String {
    "+\(added) \u{2212}\(removed)"
}

/// First capture group of `pattern` in `text`, or nil.
private func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

/// "10.2s" under a minute (integers while live), then "1m 04s", then "1h 02m".
public func nativeDurationText(_ seconds: Double, live: Bool = false) -> String {
    let seconds = max(0, seconds)
    if seconds < 60 {
        if live { return "\(Int(seconds))s" }
        let text = String(format: "%.1f", seconds)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "s"
    }
    let whole = Int(seconds)
    if whole < 3600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
    return String(format: "%dh %02dm", whole / 3600, (whole % 3600) / 60)
}

/// The header pill and sidebar dot share this state; see spec §6.
public enum NativeAgentPill: Equatable, Sendable {
    case idle, running, needsApproval, error, stopped

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .needsApproval: return "Needs you"
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }
}

public func nativeAgentPill(running: Bool, awaitingAnswer: Bool, error: Bool, stopped: Bool = false) -> NativeAgentPill {
    if error { return .error }
    if awaitingAnswer { return .needsApproval }
    if running { return .running }
    if stopped { return .stopped }
    return .idle
}

/// Consecutive non-user messages form one agent turn.
public struct NativeTurn: Identifiable, Equatable, Sendable {
    public var id: String
    public var isUser: Bool
    public var messages: [NativeThreadMessage]
}

public func nativeTurns(_ messages: [NativeThreadMessage]) -> [NativeTurn] {
    var turns: [NativeTurn] = []
    // pi's system entries (prompt-section updates) and blank messages have nothing to read; kept,
    // they render as stray notes and stretch the turn's duration to the next system update.
    // User messages always stay: they are the turn boundaries.
    for message in messages where message.role == "user" || (message.role != "system" && (message.toolName != nil
        || message.role == "toolResult" || message.truncated || message.status == "error"
        || message.blocks.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.kind == .unsupportedImage })) {
        let isUser = message.role == "user"
        if let last = turns.last, last.isUser == isUser {
            turns[turns.count - 1].messages.append(message)
        } else {
            turns.append(NativeTurn(id: message.entryID, isUser: isUser, messages: [message]))
        }
    }
    return turns
}

/// An agent turn flattened into renderable items. Consecutive tool calls collapse
/// into one group; a prose block between them splits the group.
public enum NativeTurnItem: Equatable, Sendable {
    case thinking(String)
    case prose(String)
    case tools([NativeThreadMessage])
    /// Compaction and branch summaries, or an image that cannot render natively.
    case note(String)
    /// A failed provider request (pi's `stopReason: "error"`); consecutive identical ones fold into a count.
    case error(String, count: Int)
}

public func nativeTurnItems(_ messages: [NativeThreadMessage]) -> [NativeTurnItem] {
    var items: [NativeTurnItem] = []
    for message in messages {
        if message.toolName != nil || message.role == "toolResult" {
            if case .tools(let group) = items.last {
                items[items.count - 1] = .tools(group + [message])
            } else {
                items.append(.tools([message]))
            }
            continue
        }
        if message.role == "assistant", message.status == "error" {
            let text = message.blocks.filter { $0.kind == .text }.map(\.text).last ?? "Request failed"
            if case .error(let last, let count) = items.last, last == text { items[items.count - 1] = .error(text, count: count + 1) }
            else { items.append(.error(text, count: 1)) }
            continue
        }
        for block in message.blocks {
            switch block.kind {
            case .thinking: items.append(.thinking(block.text))
            case .unsupportedImage: items.append(.note("Image attached"))
            case .text:
                if message.role == "assistant" || message.role == "user" {
                    items.append(.prose(block.text))
                } else {
                    // Extension messages ("custom") already say what they are; other roles name themselves.
                    items.append(.note(message.role == "custom" ? block.text : message.role.replacingOccurrences(of: "_", with: " ") + " · " + block.text))
                }
            }
        }
        if message.truncated { items.append(.note("Output truncated")) }
    }
    return items
}

/// "6 tool calls · read 1 · edit 3 · bash 2" for the phone's collapsed group.
public func nativeToolGroupSummary(_ messages: [NativeThreadMessage]) -> String {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for message in messages {
        let name = message.toolName ?? "result"
        if counts[name] == nil { order.append(name) }
        counts[name, default: 0] += 1
    }
    let total = messages.count
    let head = "\(total) tool call\(total == 1 ? "" : "s")"
    return ([head] + order.map { "\($0) \(counts[$0]!)" }).joined(separator: " · ")
}

/// Head-truncate a path so the filename survives: "…pp/DesktopNativeThreadView.swift".
public func nativeHeadTruncated(_ path: String, max: Int) -> String {
    guard path.count > max, max > 1 else { return path }
    return "…" + path.suffix(max - 1)
}

/// Label for the persistent tail indicator while the agent runs: the running tool wins,
/// then a thinking block that is still streaming, otherwise plain work.
public func nativeWorkingLabel(_ provisional: [NativeThreadMessage]) -> String {
    if let tool = provisional.last(where: { $0.toolName != nil && $0.status == "running" })?.toolName {
        return "Running \(tool)…"
    }
    if let last = provisional.last(where: { $0.role == "assistant" })?.blocks.last, last.kind == .thinking {
        return "Thinking…"
    }
    return "Working…"
}

// MARK: Subagent cards (docs/design-spec/subagent-card-states.png)

/// The four card states. `running` covers queued; every non-complete terminal state
/// (failed/stopped/rejected) renders as failed, since all of them end without a result.
public enum NativeSubagentState: Equatable, Sendable { case running, needsYou, done, failed }

public func nativeSubagentState(_ run: ChildRun) -> NativeSubagentState {
    if run.needsAttention { return .needsYou }
    switch run.state {
    case "running", "queued": return .running
    case "complete": return .done
    default: return run.isTerminal ? .failed : .running
    }
}

/// A turn's subagents placed where their spawn calls were: `byToolCall` keys the cards that
/// replace their `shepherd_child_start` row; `trailing` are the turn's cards with no matching
/// row (rendered after the turn's last item).
public struct NativeSubagentPlacement: Equatable, Sendable {
    public var byToolCall: [String: [ChildRun]] = [:]
    public var trailing: [ChildRun] = []
    public init(byToolCall: [String: [ChildRun]] = [:], trailing: [ChildRun] = []) {
        self.byToolCall = byToolCall
        self.trailing = trailing
    }
    public var all: [ChildRun] { byToolCall.values.flatMap { $0 } + trailing }
    public var isEmpty: Bool { byToolCall.isEmpty && trailing.isEmpty }
}

/// Every subagent belongs to the turn whose tool rows contain its spawn call. Runs whose spawn
/// call is in no loaded turn (older publishes, paged-out history) attach to the last agent
/// turn as trailing cards, so nothing live is ever hidden.
public func nativeSubagentPlacements(_ subagents: [ChildRun], turns: [NativeTurn]) -> [String: NativeSubagentPlacement] {
    var placements: [String: NativeSubagentPlacement] = [:]
    var owner: [String: String] = [:]
    for turn in turns where !turn.isUser {
        for id in turn.messages.compactMap(\.toolCallID) { owner[id] = turn.id }
    }
    let lastAgentTurn = turns.last { !$0.isUser }?.id
    for run in subagents {
        if let id = run.toolCallID, let turnID = owner[id] {
            placements[turnID, default: NativeSubagentPlacement()].byToolCall[id, default: []].append(run)
        } else if let lastAgentTurn {
            placements[lastAgentTurn, default: NativeSubagentPlacement()].trailing.append(run)
        }
    }
    return placements
}

/// "78 turns · 82 tools · 922k tok" (middle line of a running card).
public func nativeSubagentCounters(_ run: ChildRun) -> String {
    var parts: [String] = []
    if let turns = run.turns { parts.append("\(turns) turn\(turns == 1 ? "" : "s")") }
    if let tools = run.toolCalls { parts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
    if let tokens = run.tokens { parts.append("\(nativeCompactTokens(tokens)) tok") }
    return parts.joined(separator: " · ")
}

/// "922k" / "1.6m" lower-case, as the board writes token counts.
public func nativeCompactTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
        let text = String(format: "%.1f", Double(tokens) / 1_000_000)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "m"
    }
    if tokens >= 1_000 { return "\(tokens / 1_000)k" }
    return "\(tokens)"
}

/// "2 files  +96 -3  19 tools  118k tok" (done card footer).
public func nativeSubagentResultLine(_ result: ChildResultSummary) -> [String] {
    ["\(result.files) file\(result.files == 1 ? "" : "s")", "+\(result.added) -\(result.removed)",
     "\(result.tools) tool\(result.tools == 1 ? "" : "s")", "\(nativeCompactTokens(result.tokens)) tok"]
}

/// "37m 21s" style durations for card headers and "37m" for sidebar rows. Live runs count
/// from `startedAt` to now; finished runs freeze at `endedAt`.
public func nativeSubagentElapsed(_ run: ChildRun, now: Date) -> Double? {
    guard let started = run.startedAt else { return nil }
    let end = run.isTerminal ? (run.endedAt ?? started) : now.timeIntervalSince1970 * 1000
    return max(0, (end - started) / 1000)
}

/// Header duration: "37m 21s", "4m 02s", "48s", "1h 02m".
public func nativeSubagentDurationText(_ seconds: Double) -> String {
    nativeDurationText(seconds, live: true)
}

/// Sidebar right slot: "37m", "48s", "2h".
public func nativeSubagentShortDuration(_ seconds: Double) -> String {
    let whole = Int(max(0, seconds))
    switch whole {
    case ..<60: return "\(whole)s"
    case ..<3600: return "\(whole / 60)m"
    default: return "\(whole / 3600)h"
    }
}

/// "4s ago" for the live activity line.
public func nativeAgeText(_ atMilliseconds: Double, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince1970 - atMilliseconds / 1000)
    return nativeSubagentShortDuration(seconds) + " ago"
}

/// "worker, running, 37 minutes" for the card's combined accessibility label.
public func nativeSubagentAccessibilityLabel(_ run: ChildRun, now: Date) -> String {
    let state: String = switch nativeSubagentState(run) {
    case .running: "running"
    case .needsYou: "needs you"
    case .done: "done"
    case .failed: "failed"
    }
    var parts = [run.role ?? run.label, state]
    if let seconds = nativeSubagentElapsed(run, now: now) {
        let minutes = Int(seconds) / 60
        parts.append(minutes >= 1 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(Int(seconds)) seconds")
    }
    return parts.joined(separator: ", ")
}

/// RunsStrip collapsed form: more than 3 subagents in one turn fold into a strip;
/// needs-you runs always keep their own card under it.
public struct NativeRunsStripSummary: Equatable, Sendable {
    public static let collapseThreshold = 3
    public var count: Int
    /// "7 done · 3 running · 1 needs you · 1 failed" (zero buckets omitted).
    public var states: String
    /// "581k tok · 12m" (tokens summed; duration = earliest start to latest end/now).
    public var totals: String
    public var cells: [NativeSubagentState]
    public init(count: Int, states: String, totals: String, cells: [NativeSubagentState]) {
        self.count = count; self.states = states; self.totals = totals; self.cells = cells
    }
}

public func nativeRunsStripSummary(_ runs: [ChildRun], now: Date) -> NativeRunsStripSummary {
    let ordered = runs.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    let states = ordered.map(nativeSubagentState)
    var buckets: [(String, Int)] = []
    for (label, state) in [("done", NativeSubagentState.done), ("running", .running), ("needs you", .needsYou), ("failed", .failed)] {
        let n = states.count { $0 == state }
        if n > 0 { buckets.append((label, n)) }
    }
    let tokens = ordered.compactMap(\.tokens).reduce(0, +)
    var totals: [String] = []
    if tokens > 0 { totals.append("\(nativeCompactTokens(tokens)) tok") }
    if let first = ordered.compactMap(\.startedAt).min() {
        let live = ordered.contains { !$0.isTerminal }
        let end = live ? now.timeIntervalSince1970 * 1000 : (ordered.compactMap(\.endedAt).max() ?? first)
        totals.append(nativeSubagentShortDuration((end - first) / 1000))
    }
    return NativeRunsStripSummary(count: ordered.count,
                                  states: buckets.map { "\($0.1) \($0.0)" }.joined(separator: " · "),
                                  totals: totals.joined(separator: " · "), cells: states)
}

// MARK: Completed spawn group (the ledger card)

/// The ledger replaces the per-run cards once every run in a turn's group is terminal.
public struct NativeSubagentLedger: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var run: ChildRun
        public var state: NativeSubagentState
        /// First sentence of the child's final output, tail-truncated to `summaryLimit`.
        public var summary: String
        /// "5 files · 118 tools · 41m" (zero/absent parts omitted).
        public var meta: String
        public init(run: ChildRun, state: NativeSubagentState, summary: String, meta: String) {
            self.run = run; self.state = state; self.summary = summary; self.meta = meta
        }
    }
    public static let summaryLimit = 72
    public var rows: [Row]
    /// "3 subagents"
    public var title: String
    /// "all done · 45m wall · 1.5m tok" or "2 done · 1 failed · 45m wall · 1.5m tok".
    public var status: String
    public var added: Int
    public var removed: Int
    public var files: Int
    public init(rows: [Row], title: String, status: String, added: Int, removed: Int, files: Int) {
        self.rows = rows; self.title = title; self.status = status; self.added = added; self.removed = removed; self.files = files
    }
    /// "+318 −64 · 7 files" right slot (nil when the group touched nothing).
    public var diffText: String? { files > 0 ? "\(files) file\(files == 1 ? "" : "s")" : nil }
}

/// True when a spawn group has finished: every run terminal and none still asking.
public func nativeSubagentGroupIsTerminal(_ runs: [ChildRun]) -> Bool {
    !runs.isEmpty && runs.allSatisfy { $0.isTerminal && !$0.needsAttention }
}

/// First sentence of `text`, tail-truncated with an ellipsis at `limit` characters.
public func nativeFirstSentence(_ text: String, limit: Int = NativeSubagentLedger.summaryLimit) -> String {
    let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var sentence = Substring(flat)
    var cursor = flat.startIndex
    while let end = flat[cursor...].firstIndex(where: { ".!?".contains($0) }) {
        let after = flat.index(after: end)
        // "v1.2 shipped." ends at the second period: punctuation must precede a space or the end.
        if after == flat.endIndex || flat[after].isWhitespace { sentence = flat[...end]; break }
        cursor = after
    }
    guard sentence.count > limit else { return String(sentence) }
    return String(sentence.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
}

public func nativeSubagentLedger(_ runs: [ChildRun]) -> NativeSubagentLedger {
    let ordered = runs.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    let rows = ordered.map { run -> NativeSubagentLedger.Row in
        let state = nativeSubagentState(run)
        let summary: String
        switch state {
        case .failed: summary = run.exitReason ?? run.state
        default: summary = nativeFirstSentence(run.summary ?? run.output ?? "")
        }
        var meta: [String] = []
        if let files = run.result?.files, files > 0 { meta.append("\(files) file\(files == 1 ? "" : "s")") }
        if let tools = run.toolCalls, tools > 0 { meta.append("\(tools) tool\(tools == 1 ? "" : "s")") }
        if let seconds = nativeSubagentElapsed(run, now: Date()) { meta.append(nativeSubagentShortDuration(seconds)) }
        return NativeSubagentLedger.Row(run: run, state: state, summary: summary, meta: meta.joined(separator: " · "))
    }
    let failed = rows.count { $0.state == .failed }
    var status: [String] = failed == 0 ? ["all done"] : ["\(rows.count - failed) done", "\(failed) failed"]
    if let first = ordered.compactMap(\.startedAt).min(), let last = ordered.compactMap(\.endedAt).max(), last >= first {
        status.append(nativeSubagentShortDuration((last - first) / 1000) + " wall")
    }
    let tokens = ordered.compactMap(\.tokens).reduce(0, +)
    if tokens > 0 { status.append("\(nativeCompactTokens(tokens)) tok") }
    let files = ordered.flatMap { $0.files ?? [] }
    return NativeSubagentLedger(rows: rows, title: "\(rows.count) subagent\(rows.count == 1 ? "" : "s")", status: status.joined(separator: " · "),
                                added: ordered.compactMap { $0.result?.added }.reduce(0, +), removed: ordered.compactMap { $0.result?.removed }.reduce(0, +),
                                files: Set(files.map(\.path)).count)
}

/// Sibling runs of `runID` in spawn order (the group that shares its spawn turn, else all),
/// for the inspector's ‹ › stepping and "3 of 3".
public func nativeSubagentSiblings(of runID: String, in subagents: [ChildRun], turns: [NativeTurn]) -> [ChildRun] {
    let placements = nativeSubagentPlacements(subagents, turns: turns)
    let group = placements.values.first { $0.all.contains { $0.runID == runID } }?.all ?? subagents
    return group.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
}

/// "11:09 AM" from milliseconds since epoch; `meridiem: false` gives the board's bare "11:09"
/// (inspector header, from-parent captions).
public func nativeClockText(_ milliseconds: Double, meridiem: Bool = true, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = meridiem ? "h:mm a" : "h:mm"
    return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
}

/// Turn footer time slot: "11:09 AM · 45m 12s" from the user message that opened the turn
/// to the turn's last message. nil when pi gave no timestamps.
public func nativeTurnTimeText(startedAt: Double?, endedAt: Double?) -> String? {
    guard let startedAt else { return nil }
    var parts = [nativeClockText(startedAt)]
    if let endedAt, endedAt - startedAt >= 1000 { parts.append(nativeDurationText((endedAt - startedAt) / 1000, live: true)) }
    return parts.joined(separator: " · ")
}

/// Header rollup: "3 subagents · 1.6m tok" and the pill override "1 subagent needs you".
public func nativeSubagentRollup(_ runs: [ChildRun]) -> String? {
    guard !runs.isEmpty else { return nil }
    var text = "\(runs.count) subagent\(runs.count == 1 ? "" : "s")"
    let tokens = runs.compactMap(\.tokens).reduce(0, +)
    if tokens > 0 { text += " · \(nativeCompactTokens(tokens)) tok" }
    return text
}

public func nativeSubagentNeedsYouLabel(_ runs: [ChildRun]) -> String? {
    let n = runs.count(where: \.needsAttention)
    return n > 0 ? "\(n) subagent\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") you" : nil
}

/// Composer left slot while children run: "2 of 3 subagents running · 42m".
public func nativeSubagentRunningLabel(_ runs: [ChildRun], now: Date) -> String? {
    let running = runs.filter { nativeSubagentState($0) == .running }
    guard !running.isEmpty else { return nil }
    var text = "\(running.count) of \(runs.count) subagent\(runs.count == 1 ? "" : "s") running"
    if let first = running.compactMap(\.startedAt).min() {
        text += " · \(nativeSubagentShortDuration(now.timeIntervalSince1970 - first / 1000))"
    }
    return text
}

// MARK: Sticky scroll

/// bb's sticky-bottom rule as a value: follow the tail until the user scrolls away, re-stick
/// once they return to within `threshold` of the bottom. Programmatic growth never detaches.
public struct NativeScrollFollower: Equatable, Sendable {
    /// Spec §4: the tail follows while the reader is within 80pt of the bottom.
    public static let threshold: Double = 80
    public var sticky = true
    /// Set for the duration of a wheel/drag gesture (or shortly after a wheel tick).
    public var userScrolling = false
    /// Content grew while detached; cleared on re-stick.
    public var unseen = false

    public init(sticky: Bool = true, userScrolling: Bool = false, unseen: Bool = false) {
        self.sticky = sticky
        self.userScrolling = userScrolling
        self.unseen = unseen
    }

    /// One scroll-geometry observation. Only `userIntent` detaches: the caller passes it when a
    /// live gesture or wheel tick moved the offset up with the layout unchanged. A gesture that
    /// is merely in progress while rows re-measure is layout, not the user (that stranded the
    /// view detached at the bottom with the jump pill showing). `contentGrew` is the content
    /// height rising.
    public mutating func observe(distanceFromBottom: Double, userIntent: Bool = false, contentGrew: Bool = false) {
        if distanceFromBottom <= Self.threshold {
            sticky = true
            unseen = false
            return
        }
        if userIntent { sticky = false }
        if !sticky, contentGrew { unseen = true }
    }

    /// The user asked for the tail (jump pill, send): stick and forget what was missed.
    public mutating func jumpToLatest() {
        sticky = true
        unseen = false
    }

    /// The pill shows while detached and something is happening or already happened below.
    public func showsJump(running: Bool) -> Bool { !sticky && (running || unseen) }
}

// MARK: Markdown blocks

public enum NativeMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [NativeMarkdownListItem])
    case quote(String)
    /// A fenced block; `language` is the fence's info word ("swift"), when given.
    case code(String, language: String?)
    case rule
}

public struct NativeMarkdownListItem: Equatable, Sendable {
    public var text: String
    /// One level of nesting: a sub-list, or a fenced block indented under the item.
    public var children: [NativeMarkdownBlock]
    public init(text: String, children: [NativeMarkdownBlock] = []) {
        self.text = text
        self.children = children
    }
}

/// Small block parser for agent prose: headings, lists (one nested level), blockquotes,
/// fenced code, rules, paragraphs. Inline Markdown stays inside each block's text for the
/// renderer. Fences keep their contents literal and an unclosed fence runs to the end.
public func nativeMarkdownBlocks(_ text: String) -> [NativeMarkdownBlock] {
    var blocks: [NativeMarkdownBlock] = []
    var paragraph: [String] = []
    var quote: [String] = []
    var list: (ordered: Bool, start: Int, items: [NativeMarkdownListItem])?
    var child: (ordered: Bool, start: Int, items: [NativeMarkdownListItem])?
    var listBreak = false

    func flushParagraph() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
        paragraph = []
    }
    func flushQuote() {
        if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
        quote = []
    }
    func flushChild() {
        guard let nested = child, list != nil, !list!.items.isEmpty else { child = nil; return }
        list!.items[list!.items.count - 1].children.append(.list(ordered: nested.ordered, start: nested.start, items: nested.items))
        child = nil
    }
    func flushList() {
        flushChild()
        if let list, !list.items.isEmpty { blocks.append(.list(ordered: list.ordered, start: list.start, items: list.items)) }
        list = nil
        listBreak = false
    }
    func flushAll() { flushParagraph(); flushQuote(); flushList() }
    func appendContinuation(_ text: String) {
        let separator = listBreak ? "\n\n" : "\n"
        if child != nil, !child!.items.isEmpty {
            child!.items[child!.items.count - 1].text += separator + text
        } else if list != nil, !list!.items.isEmpty {
            list!.items[list!.items.count - 1].text += separator + text
        }
        listBreak = false
    }

    let lines = text.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix(while: { $0 == " " }).count
        let fence = String(trimmed.prefix(while: { $0 == "`" }))

        if fence.count >= 3 {
            var body: [String] = []
            var next = index + 1
            var closed = false
            while next < lines.count {
                let candidate = lines[next].trimmingCharacters(in: .whitespaces)
                let marker = String(candidate.prefix(while: { $0 == "`" }))
                if marker.count >= fence.count, candidate == marker { closed = true; break }
                let lead = lines[next].prefix(while: { $0 == " " }).count
                body.append(String(lines[next].dropFirst(min(indent, lead))))
                next += 1
            }
            let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init)
            let code = NativeMarkdownBlock.code(body.joined(separator: "\n"), language: info?.isEmpty == false ? info : nil)
            if list != nil, !list!.items.isEmpty, indent >= 2 {
                // Indented under an item: the fence belongs to that item, contents stay literal.
                flushChild()
                list!.items[list!.items.count - 1].children.append(code)
                listBreak = false
            } else {
                flushAll()
                blocks.append(code)
            }
            index = closed ? next + 1 : next
            continue
        }
        index += 1

        if trimmed.isEmpty {
            flushParagraph()
            flushQuote()
            if list != nil { listBreak = true }
            continue
        }
        if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first),
           trimmed.allSatisfy({ $0 == first || $0 == " " }) {
            flushAll()
            blocks.append(.rule)
            continue
        }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
            flushAll()
            blocks.append(.heading(level: hashes, text: trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
            continue
        }
        if trimmed.hasPrefix(">") {
            flushParagraph()
            flushList()
            quote.append(String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1)))
            continue
        }
        if let item = nativeListItem(trimmed) {
            flushParagraph()
            flushQuote()
            if list == nil {
                list = (item.ordered, item.number, [])
            } else if indent < 2 {
                if list!.ordered != item.ordered || list!.items.isEmpty { flushList(); list = (item.ordered, item.number, []) }
            } else {
                if child == nil || child!.ordered != item.ordered { flushChild(); child = (item.ordered, item.number, []) }
                child!.items.append(NativeMarkdownListItem(text: item.text))
                listBreak = false
                continue
            }
            flushChild()
            list!.items.append(NativeMarkdownListItem(text: item.text))
            listBreak = false
            continue
        }
        if list != nil, !list!.items.isEmpty, !listBreak || indent >= 2 {
            appendContinuation(trimmed)
            continue
        }
        flushQuote()
        flushList()
        paragraph.append(line)
    }
    flushAll()
    return blocks
}

/// "- item", "* item", "+ item", "3. item", "3) item" → marker kind, number, and text.
private func nativeListItem(_ trimmed: String) -> (ordered: Bool, number: Int, text: String)? {
    if let first = trimmed.first, "-*+".contains(first) {
        let rest = trimmed.dropFirst()
        guard rest.first == " " else { return nil }
        return (false, 1, rest.trimmingCharacters(in: .whitespaces))
    }
    let digits = trimmed.prefix(while: \.isNumber)
    guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
    let rest = trimmed.dropFirst(digits.count)
    guard let punct = rest.first, punct == "." || punct == ")", rest.dropFirst().first == " " else { return nil }
    return (true, number, rest.dropFirst().trimmingCharacters(in: .whitespaces))
}

import Foundation
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Child runs projected onto the Agents components' values. Pure and clock-free: a live figure
/// carries the date it counts from, and `NWElapsedText` does the counting.
enum SubagentPresentation {
    /// How a turn's runs render: cards while few are live, the strip (plus the cards that need
    /// you) when many are, and the ledger once the whole group has finished.
    enum Layout: Equatable { case cards, strip, ledger }

    static func layout(_ runs: [ChildRun], turnLive: Bool) -> Layout {
        let live = turnLive || runs.contains { !$0.isTerminal }
        if !live, nativeSubagentGroupIsTerminal(runs) { return .ledger }
        return runs.count > NativeRunsStrip.collapseThreshold ? .strip : .cards
    }

    /// Spawn order.
    static func ordered(_ runs: [ChildRun]) -> [ChildRun] {
        runs.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    }

    // MARK: State

    /// A run on Night Watch's one status enum. A queued run and a run paused before its next
    /// model request both wait: hollow and outlined.
    static func state(_ run: ChildRun) -> AgentState {
        switch nativeSubagentState(run) {
        case .needsYou: .attention
        case .done: .done
        case .failed: .failed
        case .running: run.state == "queued" || run.paused == true ? .queued : .running
        }
    }

    /// The pill's word where the state's own word would mislead ("Paused" is not "Queued").
    static func stateLabel(_ run: ChildRun) -> String? {
        nativeSubagentState(run) == .running && run.paused == true ? "Paused" : nil
    }

    // MARK: Card

    static func card(_ run: ChildRun) -> NWSubagentRun {
        let (name, role) = names(run)
        let state = state(run)
        var card = NWSubagentRun(id: run.id, name: name, role: role, model: run.model.map(modelTag), state: state,
                                 stateLabel: stateLabel(run), detail: "")
        switch state {
        case .attention:
            card.detail = "waiting on your answer"
            card.waitingSince = askedAt(run)
            card.question = NWSubagentQuestion(text: run.question?.text ?? run.attentionText ?? "", options: run.question?.options ?? [])
        case .done:
            let summary = summaryLine(run)
            card.detail = summary.isEmpty ? "finished" : lineWithoutFinalPeriod(summary)
            card.detailMeta = [(run.toolCalls ?? run.result?.tools).flatMap { $0 > 0 ? plural($0, "tool") : nil },
                               duration(run).map { NWDuration.text($0) }].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            card.detail = run.exitReason ?? run.state
        case .queued:
            card.detail = run.paused == true ? "paused before its next model request" : "waiting to start"
        default:
            card.detail = activity(run)
            if let percent = run.contextPercent {
                card.progress = min(1, max(0, percent / 100))
                card.progressLabel = "Context window used"
            }
        }
        return card
    }

    /// The card's name and role tag. A native child's label is "role: task", so it is named by
    /// its role and no tag repeats it; a workflow lane is named by its key and tagged with its
    /// role.
    static func names(_ run: ChildRun) -> (name: String, role: String?) {
        guard let role = run.role, !role.isEmpty else { return (run.label, nil) }
        if run.label == role || run.label.hasPrefix("\(role): ") { return (role, nil) }
        return (run.label, role)
    }

    /// What a running child is doing: its last call, a path shortened to the file name
    /// ("edit ThreadView.swift"), else the tool in flight.
    static func activity(_ run: ChildRun) -> String {
        if let last = run.lastActivity {
            guard let preview = last.preview, !preview.isEmpty else { return last.tool }
            return "\(last.tool) \(fileName(preview))"
        }
        return run.currentTool ?? "working"
    }

    /// A native child asks through `shepherd_parent_message`, so that call's time is when it
    /// began waiting; anything else gives no honest start, and the wait shows no figure.
    static func askedAt(_ run: ChildRun) -> Date? {
        guard let last = run.lastActivity, last.tool == "shepherd_parent_message" else { return nil }
        return Date(timeIntervalSince1970: last.at / 1000)
    }

    // MARK: Ledger and strip

    static func ledger(_ runs: [ChildRun]) -> NWRunLedgerSummary {
        let ordered = ordered(runs)
        let entries = ordered.map { run -> NWRunLedgerEntry in
            let state = state(run)
            let summary = state == .failed ? (run.exitReason ?? run.state) : summaryLine(run)
            let files = run.result?.files ?? run.files?.count ?? 0
            let meta = [files > 0 ? plural(files, "file") : nil, duration(run).map { NWDuration.text($0) }].compactMap { $0 }
            return NWRunLedgerEntry(id: run.id, name: names(run).name, state: state, summary: summary, meta: meta.joined(separator: " · "))
        }
        let failed = entries.count { $0.state == .failed }
        var status = failed == 0 ? ["all done"] : ["\(entries.count - failed) done", "\(failed) failed"]
        if let span = span(ordered), let until = span.until { status.append(NWDuration.text(until.timeIntervalSince(span.since))) }
        return NWRunLedgerSummary(title: plural(entries.count, "subagent"), state: failed == 0 ? .done : .failed,
                                  status: status.joined(separator: " · "),
                                  added: ordered.compactMap { $0.result?.added }.reduce(0, +),
                                  removed: ordered.compactMap { $0.result?.removed }.reduce(0, +), entries: entries)
    }

    /// The strip counts each run as its cell and pill draw it: queued and paused runs wait
    /// (hollow cells), so neither is tallied as running.
    static func strip(_ runs: [ChildRun]) -> NWRunsStripSummary {
        let ordered = ordered(runs)
        let cells = ordered.map(state)
        let words = ordered.map(tallyWord)
        let tally = ["done", "running", "queued", "paused", "needs you", "failed"].compactMap { word -> String? in
            let n = words.count { $0 == word }
            return n > 0 ? "\(n) \(word)" : nil
        }
        let tokens = ordered.compactMap(\.tokens).reduce(0, +)
        let glyph = [AgentState.attention, .running, .queued, .failed].first(where: cells.contains) ?? .done
        let span = span(ordered)
        return NWRunsStripSummary(title: plural(ordered.count, "subagent"), state: glyph, cells: cells,
                                  states: tally.joined(separator: " · "), tokens: tokens > 0 ? "\(nativeCompactTokens(tokens)) tok" : nil,
                                  since: span?.since, until: span?.until)
    }

    /// A run's word in the strip's tally: its pill's word, lowercased.
    private static func tallyWord(_ run: ChildRun) -> String {
        switch state(run) {
        case .attention: "needs you"
        case .done: "done"
        case .failed: "failed"
        case .queued: stateLabel(run) == nil ? "queued" : "paused"
        default: "running"
        }
    }

    /// The group's time: from its first start, until its last end once every run finished.
    static func span(_ runs: [ChildRun]) -> (since: Date, until: Date?)? {
        guard let first = runs.compactMap(\.startedAt).min() else { return nil }
        let until = runs.allSatisfy(\.isTerminal) ? runs.compactMap(\.endedAt).max().map { Date(timeIntervalSince1970: max(first, $0) / 1000) } : nil
        return (Date(timeIntervalSince1970: first / 1000), until)
    }

    // MARK: Inspector

    /// The header's mono line and its state-colored accent: a live run's model, thinking,
    /// turns and tokens; a finished run's model and turns, then "done 11:02".
    static func inspectorMeta(_ run: ChildRun, timeZone: TimeZone = .current) -> (meta: String, accent: String?) {
        var parts: [String] = []
        if let model = run.model { parts.append(modelTag(model)) }
        if !run.isTerminal, let thinking = run.thinking, thinking != "off" { parts.append("thinking \(thinking)") }
        if let turns = run.turns { parts.append(plural(turns, "turn")) }
        if !run.isTerminal, let tokens = run.tokens { parts.append("\(nativeCompactTokens(tokens)) tok") }
        guard run.isTerminal else { return (parts.joined(separator: " · "), nil) }
        let word = run.state == "complete" ? "done" : run.state
        return (parts.joined(separator: " · "), run.endedAt.map { "\(word) \(nativeClockText($0, meridiem: false, timeZone: timeZone))" } ?? word)
    }

    /// "step 1 / 1 · 62%" beside a live run's goal.
    static func goalNote(_ run: ChildRun) -> String? {
        guard !run.isTerminal else { return nil }
        var parts: [String] = []
        if let step = run.step { parts.append("step \(step.index) / \(step.total)") }
        if let percent = run.contextPercent { parts.append("\(Int(percent.rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1 more file" under the touched files the inspector lists, of `count` in all.
    static func moreFiles(_ count: Int) -> String {
        plural(count - AppLayout.inspectorMaxFiles, "more file")
    }

    // MARK: Helpers

    /// The layout truncates; this only keeps a runaway first sentence short.
    static let summaryLimit = 160

    /// What a finished run did, as one plain line: the first sentence of its summary (else its
    /// output) without inline Markdown markers ("**macOS**" reads "macOS").
    static func summaryLine(_ run: ChildRun) -> String {
        let sentence = nativeFirstSentence(run.summary ?? run.output ?? "", limit: summaryLimit)
        guard let parsed = try? AttributedString(markdown: sentence, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return sentence
        }
        return String(parsed.characters)
    }

    /// "claude-sonnet" from "anthropic/claude-sonnet".
    static func modelTag(_ model: String) -> String {
        model.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? model
    }

    /// A path's file name ("Sources/A/B.swift" → "B.swift"); anything else as is.
    static func fileName(_ preview: String) -> String {
        guard preview.contains("/"), !preview.contains(where: \.isWhitespace),
              let name = preview.split(separator: "/").last, !name.isEmpty else { return preview }
        return String(name)
    }

    /// A sentence as the head of a " · "-joined line ("2 spec deviations fixed · 26 tools");
    /// an ellipsis, "!" or "?" stays.
    static func lineWithoutFinalPeriod(_ sentence: String) -> String {
        sentence.hasSuffix(".") && !sentence.hasSuffix("..") ? String(sentence.dropLast()) : sentence
    }

    /// A finished run's duration.
    static func duration(_ run: ChildRun) -> TimeInterval? {
        guard run.isTerminal, let started = run.startedAt, let ended = run.endedAt else { return nil }
        return max(0, (ended - started) / 1000)
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

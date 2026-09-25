import Foundation
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Child runs projected onto the Agents components' values (the tray and the inspector). Pure
/// and clock-free: a live figure carries the date it counts from, and `NWElapsedText` does the
/// counting.
enum SubagentPresentation {
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

    // MARK: Tray

    /// A phase on Night Watch's one status enum: queued and paused runs both wait.
    static func state(_ phase: NativeRunPhase) -> AgentState {
        switch phase {
        case .running: .running
        case .queued, .paused: .queued
        case .needsYou: .attention
        case .done: .done
        case .failed: .failed
        }
    }

    /// The store's tray as the tray's rows and header draw it.
    static func tray(_ tray: NativeSubagentTray) -> (summary: NWSubagentTraySummary, rows: [NWSubagentTrayRun]) {
        let summary = NWSubagentTraySummary(title: tray.title, cells: tray.cells.map(state),
                                            tally: tray.tally.map { NWSubagentTraySummary.Part($0.text, state: $0.phase.map(state)) })
        return (summary, tray.rows.map(row))
    }

    static func row(_ row: NativeTrayRow) -> NWSubagentTrayRun {
        let line: NWSubagentTrayRun.Line = switch row.line {
        case .working(let verb, let subject, let live): .working(verb: verb, subject: subject, live: live)
        case .waiting(let text): .waiting(text)
        case .asks(let question): .asks(question)
        case .result(let text): .result(text)
        case .failed(let reason): .failed(reason)
        }
        return NWSubagentTrayRun(id: row.id, name: row.name, state: state(row.phase), line: line, added: row.added, removed: row.removed,
                                 since: row.since.map(date), until: row.until.map(date), accessibilityLabel: row.accessibilityLabel)
    }

    private static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// A run's name and role tag. A native child's label is "role: task", so it is named by
    /// its role and no tag repeats it; a workflow lane is named by its key and tagged with its
    /// role.
    static func names(_ run: ChildRun) -> (name: String, role: String?) {
        guard let role = run.role, !role.isEmpty else { return (run.label, nil) }
        if run.label == role || run.label.hasPrefix("\(role): ") { return (role, nil) }
        return (run.label, role)
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

import Foundation
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Child runs projected onto the Agents components' values (the tray and the inspector). Pure
/// and clock-free: a live figure carries the date it counts from, and `NWElapsedText` does the
/// counting.
enum SubagentPresentation {
    // MARK: State

    /// A run on Night Watch's one status enum. A queued run, a run paused before its next model
    /// request and a run waiting on its parent's answer all wait: hollow and outlined. None of
    /// them is `attention`, which is the user's.
    static func state(_ run: ChildRun) -> AgentState {
        switch nativeSubagentState(run) {
        case .asked: .queued
        case .done: .done
        case .failed: .failed
        case .running: run.state == "queued" || run.paused == true ? .queued : .running
        }
    }

    /// Done, failed or stopped, and asking nothing: nothing more happens to it unless it is re-run.
    /// A run waiting on its parent's answer is not finished.
    static func isFinished(_ run: ChildRun) -> Bool {
        !nativeRunPhase(run).isLive
    }

    /// What a run that asked its parent shows in place of a result: its question, then the answers
    /// it offered. nil for a run that asks nothing.
    static func askedText(_ run: ChildRun) -> String? {
        guard nativeRunPhase(run) == .asked else { return nil }
        let question = run.question?.text ?? run.attentionText ?? ""
        guard !question.isEmpty else { return nil }
        let options = run.question?.options ?? []
        return options.isEmpty ? question : question + "\n\nIt offered: " + options.joined(separator: " · ")
    }

    /// The pill's word where the state's own word would mislead ("Paused" is not "Queued").
    static func stateLabel(_ run: ChildRun) -> String? {
        if nativeSubagentState(run) == .asked { return "Waiting on parent" }
        return nativeSubagentState(run) == .running && run.paused == true ? "Paused" : nil
    }

    // MARK: Tray

    /// A phase on Night Watch's one status enum: queued runs, paused runs and runs waiting on
    /// their parent all wait.
    static func state(_ phase: NativeRunPhase) -> AgentState {
        switch phase {
        case .running: .running
        case .queued, .paused, .asked: .queued
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
        case .asked(let question): .asked(question)
        case .result(let text): .result(text)
        case .failed(let reason): .failed(reason)
        }
        return NWSubagentTrayRun(id: row.id, name: row.name, role: row.role, state: state(row.phase), line: line, added: row.added, removed: row.removed,
                                 since: row.since.map(date), until: row.until.map(date), accessibilityLabel: row.accessibilityLabel)
    }

    private static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Shared task names and secondary roles, with explicit workflow lane names kept.
    static func names(_ run: ChildRun) -> (name: String, role: String?) {
        nativeRunNames(run)
    }

    // MARK: Inspector

    /// The shared secondary role and metadata, ending with a finished run's state-colored time.
    static func inspectorMeta(_ run: ChildRun, timeZone: TimeZone = .current) -> (meta: String, accent: String?) {
        nativeRunInspectorMeta(run, timeZone: timeZone)
    }

    /// "step 1 / 1 · 62%" beside a live run's goal.
    static func goalNote(_ run: ChildRun) -> String? {
        guard !run.isTerminal else { return nil }
        var parts: [String] = []
        if let step = run.step { parts.append("step \(step.index) / \(step.total)") }
        if let percent = run.contextPercent { parts.append(nativeContextPercentText(percent)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1 more file" under the touched files the inspector lists, of `count` in all.
    static func moreFiles(_ count: Int) -> String {
        plural(count - AppLayout.inspectorMaxFiles, "more file")
    }

    /// "turn 4 of 11" (SubagentsDone): where a finished run's transcript is read, counted in the
    /// run's turns (one per reply of the model, as the header's count) up to the first reply
    /// at or after the topmost turn on screen, of `total` (the transcript's own count when the run
    /// reported none). Nil with no replies, or no turn on screen.
    static func position(turns: [NativeTurn], top: String?, total: Int?) -> String? {
        guard let top, let index = turns.firstIndex(where: { $0.id == top }) else { return nil }
        let replies = { (turn: NativeTurn) in turn.messages.count { $0.role == "assistant" } }
        let all = turns.reduce(0) { $0 + replies($1) }
        guard all > 0 else { return nil }
        let before = turns[..<index].reduce(0) { $0 + replies($1) }
        let count = max(total ?? all, all)
        return "turn \(min(before + 1, count)) of \(count)"
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

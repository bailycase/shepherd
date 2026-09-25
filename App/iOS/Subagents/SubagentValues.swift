import Foundation
import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

extension MobileLayout {
    /// The iPad inspector beside the thread (iPadSteer, iPadSubagents boards).
    static let subagentInspectorMinWidth: CGFloat = 340
    static let subagentInspectorIdealWidth: CGFloat = 400
    static let subagentInspectorMaxWidth: CGFloat = 480
    /// Sibling runs shown as tabs over the inspector; more step with ‹ › instead.
    static let subagentTabsMax = 4
    /// Rows a group card lists in the thread before "Open" takes over.
    static let subagentGroupMaxRows = 6
    /// Space between a section's head and its cards.
    static let subagentSectionSpacing: CGFloat = NW.Space.m
}

extension AgentState {
    /// A run's phase: a queued run and a run paused before its next model request both wait.
    init(_ phase: NativeRunPhase) {
        switch phase {
        case .running: self = .running
        case .queued, .paused: self = .queued
        case .needsYou: self = .attention
        case .done: self = .done
        case .failed: self = .failed
        }
    }
}

/// Child runs projected onto the touch components' values (the Mac's SubagentPresentation).
enum SubagentValues {
    static func date(_ milliseconds: Double?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    static func card(_ summary: NativeRunSummary) -> NWRunCardValue {
        NWRunCardValue(
            id: summary.id, name: summary.name, tags: summary.tags, state: AgentState(summary.phase),
            stateLabel: summary.phase == .paused ? nativeRunPhaseLabel(.paused) : nil, detail: summary.detail,
            step: summary.step, progress: summary.progress, progressLabel: summary.progress == nil ? nil : "Context window used",
            tokens: summary.tokens, question: summary.question, options: summary.options,
            since: date(summary.startedAt), until: date(summary.endedAt), waitingSince: date(summary.askedAt),
            added: summary.added, removed: summary.removed)
    }

    static func groupRow(_ summary: NativeRunSummary) -> NWRunGroupRow {
        let live = summary.phase.isLive
        return NWRunGroupRow(
            id: summary.id, name: summary.name, state: AgentState(summary.phase), detail: summary.compactDetail,
            meta: live ? nil : summary.meta,
            since: summary.phase == .needsYou ? date(summary.askedAt) : date(summary.startedAt),
            until: live ? nil : date(summary.endedAt))
    }

    static func historyRow(_ summary: NativeRunSummary) -> NWRunHistoryRow {
        NWRunHistoryRow(id: summary.id, name: summary.name, state: AgentState(summary.phase), summary: summary.detail,
                        finishedAt: date(summary.endedAt), added: summary.added, removed: summary.removed)
    }
}

/// What the subagents screens show for one thread, derived once per change of its runs.
struct SubagentList: Equatable {
    var current: [NativeRunSummary] = []
    var earlier: [NativeRunSummary] = []
    var tally: String?
    var tallyState: AgentState = .idle

    var isEmpty: Bool { current.isEmpty && earlier.isEmpty }

    /// What the list is derived from: the runs and where they were spawned.
    struct Key: Equatable {
        var runs: [NativeSubagent]
        var placements: [String: NativeSubagentPlacement]

        @MainActor init(_ store: NativeThreadStore) {
            runs = store.subagents
            placements = store.placements
        }
    }

    init() {}

    @MainActor init(_ store: NativeThreadStore) {
        let sections = nativeRunSections(store.subagents, placements: store.placements, turnOrder: store.rows.map(\.id))
        current = sections.current.map(nativeRunSummary)
        earlier = sections.earlier.map(nativeRunSummary)
        if let tally = nativeRunTally(store.subagents) {
            self.tally = tally.text
            tallyState = AgentState(tally.phase)
        }
    }
}

/// Sends a run's commands through the thread's store. A command the host refuses shows as the
/// store's notice.
@MainActor
struct SubagentCommands {
    let store: NativeThreadStore
    let enabled: Bool

    func send(_ runID: String, _ command: NativeRunCommand?) {
        guard enabled, let command else { return }
        Task { await store.subagentCommand(runID: runID, action: command.action, text: command.text, mode: command.mode) }
    }

    func answer(_ runID: String) -> (String) -> Void {
        { send(runID, .answer($0)) }
    }

    func control(_ runID: String, _ control: NativeRunControl) {
        send(runID, NativeRunCommand(control))
    }
}

extension NativeThreadStore {
    /// The host takes subagent commands for this thread now.
    var takesSubagentCommands: Bool { isLive && supports("subagents") }
}

/// A run's Pause or Continue, Stop, and Re-run, as menu items.
struct SubagentControlItems: View {
    let run: NativeSubagent
    let commands: SubagentCommands

    var body: some View {
        ForEach(nativeRunControls(run), id: \.self) { control in
            Button(control.title, systemImage: Self.symbol(control), role: control == .stop ? .destructive : nil) {
                commands.control(run.runID, control)
            }
            .disabled(!commands.enabled)
        }
    }

    static func symbol(_ control: NativeRunControl) -> String {
        switch control {
        case .pause: "pause"
        case .continue: "play"
        case .stop: "stop"
        case .rerun: "arrow.clockwise"
        }
    }
}

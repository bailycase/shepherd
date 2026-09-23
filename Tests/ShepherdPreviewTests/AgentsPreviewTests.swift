import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import SwiftUI
import Testing
@testable import ShepherdApp

/// Subagent surfaces (Agents board) in light and dark: the cards in every state, the runs
/// strip, the ledger, a live group and a finished one in a thread, and the inspector on a live
/// and a finished run. See `PreviewTests` for how previews run.
@Suite("Agents previews", .serialized, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct AgentsPreviewTests {
    private let actions = SubagentActions(inspect: { _ in }, command: { _, _, _, _ in }, enabled: true)

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    /// The board's four states plus a paused and a queued run; the reviewer asked through
    /// `shepherd_parent_message` 2m 10s ago.
    private static var cardRuns: [ChildRun] {
        var runs = Threads.liveRuns
        runs[1].lastActivity = ChildActivity(tool: "shepherd_parent_message", at: nowMs - 130_000)
        var paused = runs[0]
        paused.runID = "native-docs-paused"
        paused.label = "docs: rewrite the subagent guide"
        paused.role = "docs"
        paused.paused = true
        var queued = ChildRun(runID: "native-lint", label: "lint", state: "queued", startedAt: nowMs, role: "linter",
                              model: "anthropic/claude-haiku-4-5", toolCallID: "spawn-lint")
        queued.context = "async"
        return runs + [paused, queued]
    }

    /// Twelve parallel runs: seven done, three running, one asking, one failed.
    private static var manyRuns: [ChildRun] {
        let live = cardRuns
        return (0..<12).map { index -> ChildRun in
            var run = live[index < 7 ? 2 : index < 10 ? 0 : index == 10 ? 1 : 3]
            run.runID = "strip-\(index)"
            run.startedAt = (run.startedAt ?? nowMs) + Double(index)
            return run
        }
    }

    private func renderThread(_ surface: String, _ fixture: ThreadFixture, size: CGSize, inspected: String? = nil) async throws {
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready }) {
            fixture.thread(inspected: inspected)
        }
    }

    @Test func subagentCardsInEveryState() async throws {
        let actions = actions
        let cards = Self.cardRuns
        try await Preview.render("subagent-cards", size: CGSize(width: 760, height: 1240)) {
            VStack(alignment: .leading, spacing: NW.Space.xl) {
                Text("Cards").nwSectionLabel()
                VStack(alignment: .leading, spacing: AppLayout.subagentStackSpacing) {
                    ForEach(cards, id: \.id) { run in
                        SubagentCard(run: run, selected: run.runID == "native-worker", enabled: true, inspect: { _ in }, command: { _, _, _, _ in })
                    }
                }
                Text("Many parallel runs").nwSectionLabel()
                SubagentStack(runs: Self.manyRuns, turnLive: true, actions: actions)
                Text("Finished group").nwSectionLabel()
                SubagentStack(runs: Threads.doneRuns, actions: {
                    var ledger = actions
                    ledger.inspectedRunID = "native-tests"
                    return ledger
                }())
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    @Test func threadSubagentsLive() async throws {
        let runs = Array(Self.cardRuns.prefix(3))
        try await renderThread("thread-subagents-live", ThreadFixture(Threads.subagents(runs, running: true)),
                               size: CGSize(width: 800, height: 900), inspected: "native-worker")
    }

    @Test func threadSubagentsLedger() async throws {
        try await renderThread("thread-subagents-ledger", ThreadFixture(Threads.subagents(Threads.doneRuns, running: false)),
                               size: CGSize(width: 800, height: 800), inspected: "native-tests")
    }

    @Test func threadSubagentInspector() async throws {
        let fixture = ThreadFixture(Threads.subagents(Array(Self.cardRuns.prefix(3)), running: true))
        fixture.transcripts["native-worker"] = Threads.workerTranscript
        defer { fixture.store.stop() }
        let panes = RightPaneState()
        panes.runByAgent[AgentID(rawValue: "a")] = "native-worker"
        try await Preview.render("thread-subagent-inspector", size: CGSize(width: 1370, height: 900), ready: { fixture.store.ready }) {
            RightPaneSplit(state: panes, showPane: true) {
                fixture.thread(inspected: "native-worker")
            } pane: {
                SubagentInspector(store: fixture.store, runID: "native-worker", active: true, close: {}, select: { _ in }, fork: { _ in nil })
            }
        }
    }

    @Test func threadSubagentInspectorFinished() async throws {
        let fixture = ThreadFixture(Threads.subagents(Threads.doneRuns, running: false))
        fixture.transcripts["native-tests"] = Threads.testsTranscript
        defer { fixture.store.stop() }
        let panes = RightPaneState()
        panes.runByAgent[AgentID(rawValue: "a")] = "native-tests"
        try await Preview.render("thread-subagent-inspector-finished", size: CGSize(width: 1370, height: 900), ready: { fixture.store.ready }) {
            RightPaneSplit(state: panes, showPane: true) {
                fixture.thread(inspected: "native-tests")
            } pane: {
                SubagentInspector(store: fixture.store, runID: "native-tests", active: true, close: {}, select: { _ in },
                                  fork: { _ in nil }, review: { _ in })
            }
        }
    }
}

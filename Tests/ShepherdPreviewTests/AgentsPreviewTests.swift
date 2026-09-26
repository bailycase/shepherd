import AppKit
import Foundation
import ShepherdCore
@testable import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import SwiftUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Subagent surfaces (SubagentTray, Subagents, SubagentsDone, SubagentsQueue, NWAgents boards)
/// in light and dark: the tray's states, rows, record and touch sizes; a live thread with the
/// tray, a finished one, one with Up next in the same card; and the inspector on a live and a
/// finished run. See `PreviewTests` for how previews run.
@Suite("Agents previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct AgentsPreviewTests {
    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    private func renderThread(_ surface: String, _ fixture: ThreadFixture, size: CGSize, inspected: String? = nil) async throws {
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready && fixture.store.tray != nil }) {
            fixture.thread(inspected: inspected)
        }
    }

    // MARK: The tray, as a component sheet (SubagentTray board)

    private static var live: NativeSubagentTray { NativeSubagentTray(Array(Threads.liveRuns.prefix(3))) }
    private static var done: NativeSubagentTray { NativeSubagentTray(Threads.doneRuns) }

    /// Eight runs: one asking, three running, three done, one failed (SubagentTray · 8 subagents).
    private static var eight: NativeSubagentTray {
        let runs = Threads.liveRuns
        func copy(_ run: ChildRun, _ id: String, _ role: String, file: String? = nil, offset: Double) -> ChildRun {
            var run = run
            run.runID = id
            run.label = role
            run.role = role
            run.startedAt = (run.startedAt ?? nowMs) + offset
            if let file {
                run.lastActivity = ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/App/\(file)", at: nowMs)
                run.files = [ChildFileChange(path: file, added: 40, removed: 12)]
            }
            return run
        }
        var failed = runs[3]
        failed.label = "port-review"
        failed.role = "port-review"
        failed.result = ChildResultSummary(files: 1, added: 40, removed: 12, tools: 1, tokens: 1)
        return NativeSubagentTray([runs[0], runs[1], copy(runs[0], "composer", "port-composer", file: "ComposerView.swift", offset: 1),
                                   copy(runs[0], "settings", "port-settings", file: "SettingsView.swift", offset: 2), failed,
                                   runs[2], copy(runs[2], "t2", "docs", offset: 3), copy(runs[2], "t3", "lint", offset: 4)])
    }

    private struct Sheet<Content: View>: View {
        let title: String
        let note: String
        let width: CGFloat?
        @ViewBuilder let content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                content()
                    .padding(NW.Space.xl)
                    .frame(maxWidth: .infinity)
                    .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
                Text(title).font(.nwMono(11)).foregroundStyle(Color.nw.textSecondary)
                Text(note).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
        }
    }

    private static let noActions = NWSubagentTrayActions(open: {}, answer: {}, steer: {}, stop: {})

    private static func tray(_ tray: NativeSubagentTray, size: NWSubagentTraySize = .pointer, collapsed: Bool = false,
                             hovered: String? = nil, selected: String? = nil, shown: Int? = nil) -> some View {
        let values = SubagentPresentation.tray(tray)
        let rows = shown.map { Array(values.rows.prefix($0)) } ?? values.rows
        return NWSubagentTray(values.summary, size: size, collapsed: collapsed, onToggle: {}) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    NWSubagentTrayRow(row, size: size, selected: row.id == selected, hovering: row.id == hovered, actions: noActions)
                }
                if let shown, values.rows.count > shown {
                    NWSubagentTrayMoreRow(hidden: values.rows.count - shown, expanded: false) {}
                }
            }
        }
    }

    private static func dock(_ content: some View, queue: Bool = false, size: NWSubagentTraySize = .pointer) -> some View {
        VStack(spacing: NW.Space.m) {
            NWDockStack(size: size, showsTray: true, showsQueue: queue) {
                content
            } queue: {
                NWQueueStack(count: 1, collapsed: false, framed: false, onToggle: {}) {
                    NWQueueRow("Then open a draft PR.", kind: .queued(number: 1))
                } options: {
                    EmptyView()
                }
            }
            NWComposer(isFocused: false) {} field: {
                Text("Follow up, or / for commands…").font(.nw(.body)).foregroundStyle(Color.nw.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: {
                Spacer()
            }
        }
    }

    @Test func subagentTray() async throws {
        let live = Self.live, done = Self.done, eight = Self.eight
        let rows = SubagentPresentation.tray(live).rows
        let states = [(rows[0], "running · hover", true, false), (rows[1], "needs you", false, false), (rows[0], "selected (inspector open)", false, true),
                      (rows[2], "done", false, false), (SubagentPresentation.tray(eight).rows[4], "failed", false, false)]
        try await Preview.render("subagent-tray", size: CGSize(width: 1600, height: 1400)) {
            VStack(alignment: .leading, spacing: 36) {
                Text("Tray").nwSectionLabel()
                HStack(alignment: .top, spacing: NW.Space.xl) {
                    Sheet(title: "SubagentTray · running", note: "Hover a row to steer, stop or open it. Rows open the inspector in the side pane.", width: nil) {
                        Self.dock(Self.tray(live, hovered: rows[0].id))
                    }
                    Sheet(title: "SubagentTray · all done", note: "Stays until you send your next message, then folds into the thread's record.", width: nil) {
                        Self.dock(Self.tray(done))
                    }
                    Sheet(title: "SubagentTray · collapsed", note: "One line. The cells and counts still say who needs you.", width: nil) {
                        Self.dock(Self.tray(live, collapsed: true))
                    }
                }
                HStack(alignment: .top, spacing: NW.Space.xl) {
                    Sheet(title: "DockStack · subagents + Up next", note: "One card, two sections. Each collapses on its own.", width: nil) {
                        Self.dock(Self.tray(live), queue: true)
                    }
                    Sheet(title: "SubagentTray · 8 subagents", note: "Needs-you rows sort first, then running, then finished. Four rows, then Show more.", width: nil) {
                        Self.dock(Self.tray(eight, shown: NativeSubagentTray.shownRows))
                    }
                    Sheet(title: "Answer → question dock", note: "Answer takes over the composer area, labelled with the subagent.", width: nil) {
                        QuestionDock(prompt: NativeQuestionPrompt(runID: "r", name: "reviewer",
                                                                  question: "Rename the new token names, or replace the old ones everywhere?",
                                                                  options: ["Replace everywhere (Recommended)\nOld names go; 31 call sites change.",
                                                                            "Rename the new ones\nKeeps both; adds an alias."]),
                                     enabled: true, hidden: false, focused: false, answer: { _ in }, setHidden: { _ in })
                    }
                }
                Text("Rows and the thread record").nwSectionLabel()
                HStack(alignment: .top, spacing: NW.Space.xl) {
                    Sheet(title: "SubagentRow · states", note: "", width: 760) {
                        VStack(spacing: NW.Space.m) {
                            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                                HStack(spacing: NW.Space.xl) {
                                    Text(state.1).font(.nwMono(10.5)).foregroundStyle(Color.nw.textTertiary).frame(width: 150, alignment: .leading)
                                    NWSubagentTrayRow(state.0, selected: state.3, hovering: state.2, actions: Self.noActions)
                                        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                                        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
                                }
                            }
                        }
                    }
                    Sheet(title: "SubagentRecord (in the thread)", note: "The thread keeps a line when they start and one when they finish. Both open the inspector.", width: nil) {
                        VStack(alignment: .leading, spacing: NW.Space.xs) {
                            NWSubagentRecordLine(title: "Started 3 subagents", meta: "worker · reviewer · tests", action: {})
                            NWSubagentRecordLine(title: "3 subagents finished", meta: "45m · 7 files · +318 −64", action: {})
                        }
                    }
                }
                Text("iPad and iPhone").nwSectionLabel()
                HStack(alignment: .top, spacing: NW.Space.xl) {
                    Sheet(title: "iPad · 44pt rows", note: "Same card, touch sizes.", width: 620) {
                        NWDockStack(size: .pad, showsTray: true, showsQueue: false) { Self.tray(live, size: .pad) } queue: { EmptyView() }
                    }
                    Sheet(title: "iPhone · short text", note: "Diffs drop; the question shortens. Tap a row for the subagent screen.", width: 400) {
                        NWDockStack(size: .phone, showsTray: true, showsQueue: false) { Self.tray(live, size: .phone) } queue: { EmptyView() }
                            .frame(width: 362)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 36, leading: 56, bottom: 56, trailing: 56))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    // MARK: In a thread

    /// Subagents: the turn spawned three, the tray shows them above the composer (the worker's
    /// row selected, as the inspector would show it), and the thread keeps its Started line.
    @Test func threadSubagentsLive() async throws {
        try await renderThread("thread-subagents-live", ThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true)),
                               size: CGSize(width: 800, height: 900), inspected: "native-worker")
    }

    /// SubagentsDone: all done; the tray stays until the next message, and the thread records
    /// where they started and where they finished.
    @Test func threadSubagentsDone() async throws {
        try await renderThread("thread-subagents-done", ThreadFixture(Threads.subagents(Threads.doneRuns, running: false)),
                               size: CGSize(width: 800, height: 900), inspected: "native-tests")
    }

    /// SubagentsQueue: subagents, then Up next, in one card; the second message hovered.
    @Test func threadSubagentsQueue() async throws {
        let fixture = QueueThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true),
                                         queue: QueueFixture.messages(["Then open a draft PR with the before and after screenshots.",
                                                                       "Keep the old token names as deprecated aliases."]),
                                         draft: "Also check the iPad sizes when you integrate")
        defer { fixture.store.stop() }
        try await Preview.render("thread-subagents-queue", size: CGSize(width: 1180, height: 900), ready: {
            guard fixture.store.ready, fixture.store.tray != nil, fixture.state.rows.count == 2 else { return false }
            fixture.state.hover(fixture.id(1).uuidString).hovering = true
            return true
        }) {
            fixture.thread(title: "Restyle native UI", inspect: true)
        }
    }

    @Test func threadSubagentInspector() async throws {
        let fixture = ThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true))
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

    /// The finished tests run with its touched files and inline code in its result.
    private static var doneRuns: [ChildRun] {
        var runs = Threads.doneRuns
        runs[2].summary = "Added 6 tests to `NativePresentationTests`; all 14 pass on **macOS** and iOS."
        runs[2].files = [ChildFileChange(path: "Tests/ShepherdRemoteUnitTests/NativePresentationTests.swift", added: 96, removed: 3),
                         ChildFileChange(path: "Tests/ShepherdRemoteUnitTests/Fixtures.swift", added: 22, removed: 1)]
        return runs
    }

    @Test func threadSubagentInspectorFinished() async throws {
        let fixture = ThreadFixture(Threads.subagents(Self.doneRuns, running: false))
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

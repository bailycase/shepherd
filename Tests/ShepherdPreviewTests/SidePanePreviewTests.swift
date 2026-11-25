import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdCore
import ShepherdUI
import SwiftUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The thread's side pane as a card beside the thread, its toolbar ending where the card begins (GXSidePane), in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter SidePanePreviewTests
@Suite("Side pane previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SidePanePreviewTests {
    /// The boards' workspace column: a 1600pt window less its sidebar (8 + 248) and the sidebar's 8 more.
    static let column = CGSize(width: 1344, height: 900)

    /// The workspace column as the shell composes it: the thread under the toolbar, the pane card beside both.
    struct PaneWindow<Pane: View>: View {
        let fixture: ThreadFixture
        /// A subagent run's inspector in the pane (GXSubagents): a card under the toolbar, the thread's tray showing it chosen.
        var inspected: String?
        @State private var panes = RightPaneState()
        @ViewBuilder let pane: () -> Pane

        var body: some View {
            ZStack(alignment: .top) {
                RightPaneSplit(state: panes, showPane: true, card: true, inspector: inspected != nil, publishesReserve: true) {
                    ThreadView(store: fixture.store, active: true, isFocused: false, request: fixture.request, commandKey: "preview",
                               agentName: "Investigate", workingDirectory: "~/Developer/Shepherd", inspectSubagent: { _ in },
                               inspectedRunID: inspected, review: { _ in },
                               turnActions: TurnChangesActions(review: { _, _ in }, undo: { _ in nil }, redo: { _ in nil }), listModels: nil,
                               restartPi: { _ in }, authNotice: nil,
                               authActions: ThreadAuthActions(signIn: { _ in }, useModel: { _ in }, models: { ["openai/gpt-5.3-codex"] }),
                               slashLogin: nil, contextDetailsOpen: false)
                        .environment(\.threadCommands, fixture.commands)
                        .environment(\.composerModelDefaults, fixture.modelDefaults)
                } pane: {
                    pane()
                }
                .environment(\.workspaceTopInset, AppLayout.headerHeight)
                ThreadHeader(store: fixture.store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities",
                             paneOpen: true, paneShortcut: "⇧⌘B", togglePane: {}, rename: {})
                    .padding(.trailing, inspected != nil ? 0 : panes.reserved > 0 ? panes.reserved : panes.defaultWidth + AppLayout.paneCardEdge)
            }
            .background(Color.sh.bgWindow)
        }
    }

    private func tabs(_ selected: SidePaneTab, pullRequest: Int? = 412, browser: Bool = false, files: Int = 7) -> some View {
        SHSidePaneTabs(SidePaneTabs.items(news: [], changedFiles: files, browser: browser,
                                          subagents: (5, .done), pullRequest: pullRequest),
                       selection: selected.rawValue, select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
            Button("Reset Width") {}
        }
    }

    /// GXSidePane: Changes, with Pull request, Files and Subagents beside it.
    @Test func gxSidePane() async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        let session = ChangesBoard.session(comment: false)
        try await Preview.render("gx-side-pane", size: Self.column, ready: { fixture.store.ready }) {
            PaneWindow(fixture: fixture) {
                VStack(spacing: 0) {
                    tabs(.changes)
                    ReviewPane(session: session, actions: Reviews.actions)
                }
            }
            .task { await fixture.store.run(request: fixture.request) }
        }
    }

    /// Every tab the app has, restyled the same way: Browser and Design join the four of the board.
    @Test func gxSidePaneTabs() async throws {
        try await Preview.render("gx-side-pane-tabs", size: CGSize(width: AppLayout.paneDefaultWidth, height: 200)) {
            VStack(spacing: 0) {
                tabs(.changes, browser: true)
                tabs(.pullRequest, browser: true)
                SHSidePaneTabs(SidePaneTabs.items(news: [.browser], changedFiles: 7, browser: true, subagents: (5, .running), pullRequest: 412, design: true),
                               selection: SidePaneTab.files.rawValue, select: { _ in }, closeShortcut: "⇧⌘B", close: {},
                               restore: {}) { Button("Reset Width") {} }
                Spacer()
            }
            .background(Color.sh.bgRaised)
        }
    }

    /// GXSubagents in the whole window: the real shell (sidebar, toolbar, workspace) with a thread whose store a fixture feeds, a tray row clicked
    /// (`toggleSubagentInspector`, which the row calls), and the inspector a card under the toolbar beside the thread.
    @Test func gxSubagentInspectorInTheWindow() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        var agent = Agent(name: "Investigate SwiftUI live preview capabilities", spaceID: space.id, tabID: TabID(), status: .working, nameIsFinal: true)
        let pane = LeafPane(cwd: space.path, agentID: agent.id)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        agent.tabID = tab.id
        agent.paneID = pane.id
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = workspace.vm
        vm.selectAgent(agent.id)
        let fixture = ThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true))
        fixture.transcripts["native-worker"] = Threads.workerTranscript
        defer { fixture.store.stop() }
        let store = vm.threadStores.store(for: agent.id)
        var pass: (began: Date, fed: Date?)?
        try await Preview.render("gx-subagent-inspector-window", size: CGSize(width: 1440, height: 900), ready: {
            // Each pass mounts the thread again, and its own request (nothing to say in a scratch app) takes the store: once it has,
            // the fixture's takes it back, and the pass is ready when that has held for a moment.
            let now = Date()
            let began = pass?.began ?? now
            if let fed = pass?.fed {
                guard store.ready, store.tray != nil, now.timeIntervalSince(fed) > 0.5 else { return false }
            } else if now.timeIntervalSince(began) > 0.5 {
                pass = (began, now)
                Task { await store.run(request: fixture.request) }
                return false
            } else {
                pass = (began, nil)
                return false
            }
            if vm.subagentInspector.runByAgent[agent.id] == nil { vm.toggleSubagentInspector(agentID: agent.id, runID: "native-worker") }
            guard vm.subagentInspector.runByAgent[agent.id] == "native-worker" else { return false }
            pass = nil
            return true
        }) {
            RootView(vm: vm)
        }
    }
}

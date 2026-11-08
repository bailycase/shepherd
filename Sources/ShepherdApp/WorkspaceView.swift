import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

struct WorkspaceView: View {
    var vm: ShepherdViewModel
    /// The column's size and the window, kept current without redrawing anything.
    private var column: LiveResizeColumn { vm.workspaceColumn }
    /// The column's size when the window's live resize began, until it ends: hidden layouts
    /// keep it, so a drag relays out only the visible one and a hidden shell takes one grid
    /// (one SIGWINCH) when the drag ends instead of one per step.
    @State private var frozenSize: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Every mounted layout stays mounted; switching agents only
                // changes which one is visible. Unmounting would destroy the
                // Ghostty views and force a re-attach + full replay on every
                // switch, which is what made switching flash. Hidden panes
                // keep their surfaces, scrollback, and their process's real
                // grid (see WorkspaceSelection). Each layout has a hosting
                // view of its own (`AgentLayoutDeck`), so an update in the
                // visible one never walks the hidden ones; a hidden one is an
                // `isHidden` AppKit view, and never follows a live resize
                // frame by frame. The pane's `isRendering: false` stops a
                // hidden surface's drawing via ghostty occlusion.
                let mounted = vm.mountedTabs
                let visibleTabID = vm.activeTabID
                // Each layout's values, resolved here once: a layout reruns only when its own
                // change, so a status report or another agent's review reruns none of them.
                let models = AgentLayoutModel.Resolver(vm: vm, visibleTabID: visibleTabID)
                // While the side pane covers the window, hidden layouts keep the size they had.
                let frozen = frozenSize ?? (vm.isSidePaneWide ? vm.wideFrozenSize : nil)
                AgentLayoutDeck(vm: vm, models: mounted.map { models.model(for: $0) }, frozenSize: frozen)
                    .equatable()
                    // Bounded on both sides, it always takes the column's size, so a frozen
                    // layout wider than the column never widens the shell around it.
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                if let remote = vm.selectedRemoteAgent {
                    RemoteAgentPane(vm: vm, ref: remote)
                        .id(remote)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.sh.bgWindow)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { column.size = $0 }
            .background { LiveResizeColumn.WindowReader(column: column) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
            guard let window = column.window, note.object as? NSWindow === window else { return }
            frozenSize = column.size
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
            guard let window = column.window, note.object as? NSWindow === window else { return }
            frozenSize = nil
        }
        // Every path that changes the active tab lands here: keep parking bookkeeping current.
        .onChange(of: vm.activeTabID, initial: true) { vm.noteActiveTabVisited() }
        // The first frame holds the visible layout alone; the rest mount after it, a few per
        // run-loop turn. Keyed on there being any, so layouts that start waiting after this
        // view first drew (the restored workspace adopted late) still mount.
        .task(id: vm.pendingMountTabIDs.isEmpty) { await vm.drainPendingMounts() }
        .background(Color.sh.bgWindow)
        // Window-level file/image drop routing for terminal panes; per-pane
        // SwiftUI .onDrop cannot coexist with permanently mounted hidden
        // layouts (see TerminalDropOverlay.swift).
    }
}

/// The workspace column's size and its window, written as they change and read only when a
/// live resize begins: a reference, so keeping them current redraws nothing.
@MainActor
final class LiveResizeColumn {
    var size: CGSize?
    weak var window: NSWindow?

    /// Notes the window the workspace is in.
    struct WindowReader: NSViewRepresentable {
        let column: LiveResizeColumn

        func makeNSView(context: Context) -> Reader {
            let reader = Reader()
            reader.column = column
            return reader
        }

        func updateNSView(_ reader: Reader, context: Context) {
            reader.column = column
            column.window = reader.window
        }

        final class Reader: NSView {
            weak var column: LiveResizeColumn?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                column?.window = window
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

// MARK: Agent layout

/// What one mounted layout shows, as plain values the workspace resolves (`Resolver`): the view
/// reads nothing observable, so it reruns only when one of these changes.
struct AgentLayoutModel: Equatable {
    /// The layout's thread: the agent whose pi runs in it, and its pane.
    struct Thread: Equatable {
        let agentID: AgentID
        let paneID: PaneID
        let agentName: String
        /// The pi session its history is previewed from while pi starts.
        let piSessionID: String
        /// Waiting for the first launch's copy, or not signed in: the line or card at its end.
        var authNotice: ThreadAuthNotice? = nil
        /// Where it works, for the branch card beside the transcript; nil outside a git checkout
        /// and for a design's chat.
        var branch: AgentBranchLabel? = nil
    }

    let tab: Tab
    let isVisible: Bool
    let thread: Thread?
    /// The focused pane while the layout is on screen; a hidden layout holds no focus.
    let focusedPaneID: PaneID?
    /// The subagent the side pane inspects, over its tabs.
    let inspectingRunID: String?
    /// The side pane's tab while it is open, and the tabs pi opened something in.
    var sideTab: SidePaneTab?
    var sideNews: Set<SidePaneTab> = []
    /// The side pane over the whole layout (ChangesWide).
    var sideMaximized = false
    /// The Changes tab's review, by identity.
    let review: ReviewSession?
    /// The terminal panel under the thread, and its height.
    var terminal = TerminalPanels.Panel()
    /// The thread's state while the panel is maximized over it, for its folded line; nil
    /// otherwise, so a status report reruns no other layout.
    var foldedState: AgentState?
    var terminalHeight: CGFloat = AppLayout.terminalPanelHeight
    /// The design the thread's agent draws: the layout is its canvas and chat (`DesignLayoutView`).
    var design: DesignID?
    /// That design builds a design system: the layout is the system's page and the chat
    /// (`DesignSystemLayoutView`).
    var systemBuild = false

    static func == (a: AgentLayoutModel, b: AgentLayoutModel) -> Bool {
        a.tab == b.tab && a.isVisible == b.isVisible && a.thread == b.thread && a.focusedPaneID == b.focusedPaneID
            && a.design == b.design && a.systemBuild == b.systemBuild
            && a.inspectingRunID == b.inspectingRunID && a.sideTab == b.sideTab && a.sideNews == b.sideNews
            && a.sideMaximized == b.sideMaximized && a.review === b.review
            && a.terminal == b.terminal && a.terminalHeight == b.terminalHeight && a.foldedState == b.foldedState
    }

    /// Resolves every mounted layout's model from one pass over the workspace.
    @MainActor
    struct Resolver {
        private let visibleTabID: TabID?
        private let focusedPaneID: PaneID?
        private let agentsByTab: [TabID: Agent]
        private let runs: [AgentID: String]
        private let panes: RightPaneState
        private let reviews: [AgentID: ReviewSession]
        private let terminals: TerminalPanels
        /// Each design, and whether it builds a system.
        private let designs: [DesignID: Bool]
        private let waiting: Set<AgentID>
        private let restoredAt: Date
        private let notSignedIn: [AgentID: NotSignedIn]
        private let yourLogins: Set<String>
        private let defaultModel: String?

        init(vm: ShepherdViewModel, visibleTabID: TabID?) {
            terminals = vm.terminalPanels
            designs = Dictionary(vm.state.designs.map { ($0.id, $0.buildsSystem) }, uniquingKeysWith: { first, _ in first })
            self.visibleTabID = visibleTabID
            focusedPaneID = vm.showSettings || vm.showComponentGallery || vm.showCommandPalette ? nil : vm.focusedPaneID
            agentsByTab = Dictionary(vm.state.agents.map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
            runs = vm.subagentInspector.runByAgent
            panes = vm.subagentInspector
            reviews = Dictionary(vm.reviewSessions.values.map { ($0.agentID, $0) }, uniquingKeysWith: { first, _ in first })
            waiting = vm.waitingForImport
            restoredAt = vm.restoredAt
            notSignedIn = vm.notSignedIn
            yourLogins = Set(vm.yourPi.survey?.logins.filter { $0.yours != nil }.map(\.provider) ?? [])
            defaultModel = vm.settings.agentDefaults.model ?? vm.yourPi.survey?.shepherdDefaultModel
        }

        /// The line or card at the end of an agent's thread.
        private func notice(_ agent: Agent) -> ThreadAuthNotice? {
            if let stopped = notSignedIn[agent.id] {
                return .notSignedIn(provider: stopped.provider, model: (agent.model ?? defaultModel).map(NativeModelChoices.shortName),
                                    at: stopped.at, skipped: stopped.provider.map(yourLogins.contains) ?? false)
            }
            return waiting.contains(agent.id) ? .waiting(restoredAt: restoredAt) : nil
        }

        func model(for tab: Tab) -> AgentLayoutModel {
            let visible = tab.id == visibleTabID
            let thread = agentsByTab[tab.id].flatMap { agent in
                tab.layout.leaves.first { primaryAgent(in: tab, pane: $0, agents: [agent]) != nil }
                    .map { Thread(agentID: agent.id, paneID: $0.id, agentName: agent.name, piSessionID: agent.effectivePiSessionID,
                                  authNotice: notice(agent), branch: agent.designID == nil ? AgentBranchLabel(agent: agent) : nil) }
            }
            let owner = thread.map { SidePaneOwner.local($0.agentID) }
            let terminal = terminals.panel(TerminalPanelKey(host: nil, tab: tab.id))
            let folded = terminal.shown && terminal.maximized ? agentsByTab[tab.id].map { AgentState($0.status) } : nil
            return AgentLayoutModel(tab: tab, isVisible: visible, thread: thread, focusedPaneID: visible ? focusedPaneID : nil,
                                    inspectingRunID: thread.flatMap { runs[$0.agentID] },
                                    sideTab: owner.flatMap { panes.open.contains($0) ? panes.tab(for: $0) : nil },
                                    sideNews: owner.flatMap { panes.news[$0] } ?? [],
                                    sideMaximized: owner.map { panes.maximized.contains($0) } ?? false,
                                    review: thread.flatMap { reviews[$0.agentID] },
                                    terminal: terminal, foldedState: folded, terminalHeight: terminals.height,
                                    design: agentsByTab[tab.id]?.designID.flatMap { designs[$0] != nil ? $0 : nil },
                                    systemBuild: agentsByTab[tab.id]?.designID.flatMap { designs[$0] } ?? false)
        }
    }
}

/// An agent's layout with its side pane (its tabs, or an inspected subagent over them) docked
/// beside the whole layout, never inside the thread's pane: the dock rule measures the main
/// column, so a terminal panel under the thread neither halves the width it measures nor leaves
/// the pane covering the thread. It reads only its model; `vm` is for actions.
struct AgentLayoutView: View, Equatable {
    var vm: ShepherdViewModel
    let model: AgentLayoutModel

    static func == (a: AgentLayoutView, b: AgentLayoutView) -> Bool {
        a.vm === b.vm && a.model == b.model
    }

    var body: some View {
        let _ = SHRenderProbe.tick("layout.agentLayout")
        let thread = model.thread
        let inspecting = model.inspectingRunID
        let sideTab = model.sideTab
        if let design = model.design, let thread, model.systemBuild {
            DesignSystemLayoutView(vm: vm, model: model, designID: design, thread: thread)
        } else if let design = model.design, let thread {
            DesignLayoutView(vm: vm, model: model, designID: design, thread: thread)
        } else {
            threadLayout(thread: thread, inspecting: inspecting, sideTab: sideTab)
        }
    }

    @ViewBuilder
    private func threadLayout(thread: AgentLayoutModel.Thread?, inspecting: String?, sideTab: SidePaneTab?) -> some View {
        // The layout stays the first child whether or not a pane is open, so opening one never
        // remounts a pane's surface.
        RightPaneSplit(state: vm.subagentInspector, showPane: inspecting != nil || sideTab != nil,
                       maximized: inspecting == nil && model.sideMaximized) {
            PaneTreeView(vm: vm, model: model)
        } pane: {
            if let thread {
                let agentID = thread.agentID
                let owner = SidePaneOwner.local(agentID)
                let store = vm.threadStores.store(for: agentID)
                RightPaneSlot(showing: inspecting.map { .inspector(runID: $0) }
                              ?? .tab(sideTab ?? .changes, (sideTab ?? .changes) == .changes ? model.review?.id : nil)) {
                    if let inspecting {
                        SubagentInspector(store: store, runID: inspecting, active: model.isVisible, close: { [vm] in
                            vm.closeInspector(owner)
                        }, select: { [vm] in vm.subagentInspector.runByAgent[agentID] = $0.runID }, fork: { [vm] run in
                            do { try await vm.forkSubagent(agentID: agentID, run: run); return nil } catch { return String(describing: error) }
                        }, review: { [vm] in vm.openReview(agentID: agentID, path: $0) },
                        focusSteer: vm.subagentInspector.steerRun == inspecting, steerFocused: { [vm] in vm.subagentInspector.steerRun = nil })
                        // The inspector keys its run itself, so a run switch nudges in from its side.
                        .shTransition(.content)
                    } else if let sideTab {
                        SidePaneView(vm: vm, owner: owner, tab: sideTab, news: model.sideNews, review: model.review, store: store,
                                     maximized: model.sideMaximized, active: model.isVisible,
                                     inspect: { [vm] in vm.subagentInspector.runByAgent[agentID] = $0.runID })
                            .shTransition(.content)
                    }
                }
                // The pane belongs to the thread: a click in it takes focus from a terminal pane.
                .simultaneousGesture(TapGesture().onEnded { [vm] in vm.focusedPaneID = thread.paneID })
            }
        }
    }
}

// MARK: Pane tree

struct PaneSplitPath: Hashable {
    let components: [Bool]
}

struct PaneTreeGeometry {
    struct Leaf {
        let pane: LeafPane
        let rect: CGRect
    }

    struct Separator: Identifiable {
        let id: PaneSplitPath
        let node: PaneNode
        let axis: SplitAxis
        let rect: CGRect
        let containerRect: CGRect
    }

    let leaves: [Leaf]
    let separators: [Separator]
}

/// Flattens the binary split tree into leaf and divider rectangles. A vertical
/// split makes columns; a horizontal split makes rows. The 1 px divider comes
/// out of the first child's fractional span, matching the old stack layout.
func paneTreeGeometry(
    for node: PaneNode,
    in size: CGSize,
    liveRatios: [PaneSplitPath: Double] = [:]
) -> PaneTreeGeometry {
    let bounds = CGRect(
        origin: .zero,
        size: CGSize(width: max(0, size.width), height: max(0, size.height))
    )
    var leaves: [PaneTreeGeometry.Leaf] = []
    var separators: [PaneTreeGeometry.Separator] = []

    func walk(_ node: PaneNode, in rect: CGRect, path: PaneSplitPath) {
        switch node {
        case .leaf(let pane):
            leaves.append(.init(pane: pane, rect: rect))
        case .split(let axis, let ratio, let first, let second):
            let shownRatio = liveRatios[path] ?? ratio
            let span = axis == .vertical ? rect.width : rect.height
            let separatorSpan = span > 0 ? AppLayout.dividerWidth : 0
            let firstSpan = max(0, (span - separatorSpan) * shownRatio)
            let secondSpan = max(0, span - separatorSpan - firstSpan)
            let firstRect: CGRect
            let separatorRect: CGRect
            let secondRect: CGRect

            if axis == .vertical {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstSpan, height: rect.height)
                separatorRect = CGRect(
                    x: firstRect.maxX, y: rect.minY,
                    width: separatorSpan, height: rect.height
                )
                secondRect = CGRect(
                    x: separatorRect.maxX, y: rect.minY,
                    width: secondSpan, height: rect.height
                )
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstSpan)
                separatorRect = CGRect(
                    x: rect.minX, y: firstRect.maxY,
                    width: rect.width, height: separatorSpan
                )
                secondRect = CGRect(
                    x: rect.minX, y: separatorRect.maxY,
                    width: rect.width, height: secondSpan
                )
            }

            separators.append(.init(
                id: path,
                node: node,
                axis: axis,
                rect: separatorRect,
                containerRect: rect
            ))
            walk(first, in: firstRect, path: .init(components: path.components + [false]))
            walk(second, in: secondRect, path: .init(components: path.components + [true]))
        }
    }

    walk(node, in: bounds, path: .init(components: []))
    return PaneTreeGeometry(leaves: leaves, separators: separators)
}

/// Every leaf is always a direct child of this ZStack, keyed by pane ID.
/// Changing the layout moves and resizes leaves without remounting their
/// terminal surfaces.
struct PaneTreeView: View {
    var vm: ShepherdViewModel
    /// Everything the tree draws; `vm` is for actions.
    let model: AgentLayoutModel
    @State private var liveHeight: CGFloat?

    private var tab: Tab { model.tab }
    private var containerSpace: String { "split-\(tab.id)" }

    var body: some View {
        if let thread = model.thread, tab.layout.contains(thread.paneID) {
            panel(thread: thread)
        } else {
            tree
        }
    }

    private var key: TerminalPanelKey { TerminalPanelKey(host: nil, tab: tab.id) }

    /// The thread on top and its terminal panel under it (TerminalSplit board). Every leaf stays
    /// a direct child of one ZStack keyed by pane ID, shown or not, so a tab switch or a hide
    /// never remounts a terminal's surface.
    private func panel(thread: AgentLayoutModel.Thread) -> some View {
        let panel = model.terminal
        let target = ShepherdViewModel.TerminalTarget(key: key, layout: tab.layout, thread: thread.paneID, remote: nil,
                                                      focused: model.focusedPaneID)
        return GeometryReader { geo in
            let _ = SHRenderProbe.tick("layout.paneTreeGeo")
            let appTabs = vm.terminalPanels.appTabs[key] ?? []
            let selected = TerminalPanel.selected(TerminalPanel.tabs(in: tab.layout, thread: thread.paneID) + appTabs, chosen: panel.chosenTab,
                                                  focused: model.focusedPaneID)
            let geometry = terminalPanelGeometry(for: tab.layout, thread: thread.paneID, selected: selected, shown: panel.shown,
                                                 maximized: panel.maximized, height: liveHeight ?? model.terminalHeight,
                                                 in: geo.size, appTabs: appTabs)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    Group {
                        if let app = vm.terminalPanels.appKey(leaf.pane.id) {
                            // An app's output: a read-only log, never a shell.
                            if leaf.shown { AppLogView(vm: vm, app: app) }
                        } else {
                            PaneLeafView(vm: vm, tab: tab, model: leafModel(leaf.pane, shown: leaf.shown))
                        }
                    }
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                        .opacity(leaf.shown ? 1 : 0)
                        .allowsHitTesting(leaf.shown)
                        .accessibilityHidden(!leaf.shown)
                }
                TerminalPanelChrome(geometry: geometry, threadTitle: thread.agentName, threadState: model.foldedState ?? .idle,
                                    restore: { [vm] in vm.toggleTerminalMaximized() })
                if let bar = geometry.tabBar {
                    TerminalPanelBar(vm: vm, target: target, tabs: geometry.tabs, selected: selected, maximized: panel.maximized,
                                     onScreen: model.isVisible, host: nil)
                        .frame(width: bar.width, height: bar.height)
                        .overlay(alignment: .top) {
                            if !panel.maximized {
                                TerminalPanelDivider(vm: vm, container: geo.size.height, liveHeight: $liveHeight,
                                                     coordinateSpace: containerSpace)
                                    .offset(y: -AppLayout.resizeHandleWidth / 2)
                            }
                        }
                        .offset(x: bar.minX, y: bar.minY)
                        .zIndex(2)
                }
                if let bar = geometry.tabBar {
                    TerminalMenuLayer(vm: vm, target: target, bar: bar, tabs: geometry.tabs)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(3)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .shAnimation(.content, value: panel.shown)
        }
        .coordinateSpace(.named(containerSpace))
        .modifier(TerminalActivityPoll(vm: vm, key: key, agent: thread.agentID, remote: nil,
                                       active: model.isVisible && tab.layout.leaves.count > 1))
        .onChange(of: tab.layout.leaves.map(\.id), initial: true) {
            vm.terminalPanels.reconcile(key, layout: tab.layout, thread: thread.paneID)
        }
    }

    private var tree: some View {
        GeometryReader { geo in
            let _ = SHRenderProbe.tick("layout.paneTreeGeo")
            let geometry = paneTreeGeometry(for: tab.layout, in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    PaneLeafView(vm: vm, tab: tab, model: leafModel(leaf.pane))
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .coordinateSpace(.named(containerSpace))
    }

    /// Everything a leaf draws, resolved here so the leaf itself reads nothing observable and
    /// re-renders only when one of these values changes. `shown` is false for a terminal in a
    /// hidden panel or tab (and the thread under a maximized panel): it keeps its surface but
    /// neither renders nor holds the keyboard.
    private func leafModel(_ pane: LeafPane, shown: Bool = true) -> PaneLeafModel {
        let thread = model.thread?.paneID == pane.id ? model.thread : nil
        return PaneLeafModel(
            pane: pane,
            isVisible: model.isVisible && shown,
            // Hidden layouts stay mounted, so a pane only holds keyboard focus while its own
            // layout is the visible one (`focusedPaneID` is nil otherwise); a background
            // terminal would swallow typing.
            isFocused: shown && model.focusedPaneID == pane.id,
            agentID: thread?.agentID,
            agentName: thread?.agentName ?? "",
            piSessionID: thread?.piSessionID,
            authNotice: thread?.authNotice,
            branch: thread?.branch,
            inspectingRunID: thread == nil ? nil : model.inspectingRunID,
            threadAgentID: thread == nil ? model.thread?.agentID : nil
        )
    }
}

// MARK: Panes

/// What one leaf shows, as plain values (`PaneTreeView.leafModel`).
struct PaneLeafModel: Equatable {
    let pane: LeafPane
    let isVisible: Bool
    let isFocused: Bool
    /// The agent whose pi runs in this pane; nil for a terminal pane.
    let agentID: AgentID?
    let agentName: String
    /// The agent's pi session, whose file the thread shows while pi starts.
    var piSessionID: String? = nil
    /// The line or card at the end of the thread (`ThreadAuthNotice`).
    var authNotice: ThreadAuthNotice? = nil
    var branch: AgentBranchLabel? = nil
    /// The subagent the right pane inspects (`AgentLayoutView`): the thread yields keyboard focus.
    let inspectingRunID: String?
    /// For a terminal pane, the agent whose thread its selection can be added to.
    var threadAgentID: AgentID? = nil
}

struct PaneLeafView: View, Equatable {
    var vm: ShepherdViewModel
    let tab: Tab
    let model: PaneLeafModel

    static func == (a: PaneLeafView, b: PaneLeafView) -> Bool {
        a.vm === b.vm && a.tab == b.tab && a.model == b.model
    }

    var body: some View {
        let pane = model.pane
        Group {
            if pane.isReview == true {
                PanePlaceholder(text: "review unavailable")
            } else if let agentID = model.agentID {
                // The thread is the agent's pane; the session binding still goes through the
                // store so a pi exit closes the pane. Its right pane docks beside the whole layout
                // (`AgentLayoutView`).
                let inspecting = model.inspectingRunID
                AgentThreadPane(
                    session: vm.sessions.session(for: pane, in: tab),
                    store: vm.threadStores.store(for: agentID),
                    input: vm.threadStores.input(for: agentID),
                    active: model.isVisible,
                    isFocused: model.isFocused && inspecting == nil,
                    request: { [vm] in try await vm.server.nativeThread(agentID: agentID, request: $0) },
                    preview: model.piSessionID.map { PiSessionFile.previewLoader(sessionID: $0, cwd: pane.cwd, sessionsRoot: vm.server.pi.sessionsRoot) },
                    commandKey: ThreadCommandCenter.key(local: agentID),
                    agentName: model.agentName,
                    workingDirectory: pane.cwd,
                    inspectSubagent: { [vm] in vm.toggleSubagentInspector(agentID: agentID, runID: $0.runID) },
                    steerSubagent: { [vm] in vm.steerSubagent(agentID: agentID, runID: $0.runID) },
                    inspectedRunID: inspecting,
                    review: { [vm] path in vm.selectAgent(agentID); vm.openReview(agentID: agentID, path: path) },
                    turnActions: TurnChangesActions(
                        review: { [vm] turnID, path in vm.selectAgent(agentID); vm.openTurnReview(.local(agentID), turnID: turnID, path: path) },
                        undo: { [vm] in await vm.undoTurn(.local(agentID), turnID: $0) },
                        redo: { [vm] in await vm.redoTurn(.local(agentID), turnID: $0) }),
                    restartPi: { [vm] in vm.retryAgentStart(agentID, newConversation: $0) },
                    authNotice: model.authNotice,
                    authActions: ThreadAuthActions(
                        signIn: { [vm] provider in vm.openSignIn(provider, origin: .agentCard) },
                        useModel: { [vm] model in vm.useAnotherModel(agentID, model: model) },
                        models: { [vm] in await ModelCatalog.loadLocal(from: vm.server.pi.catalog).models.map(\.id) }),
                    slashLogin: vm.slashLoginActions
                )
                // Design references reach an ordinary thread only.
                .environment(\.designReferences, vm.designReferenceChips(for: agentID))
                // A login that no longer works: the error card's Sign in again opens the provider's sign-in.
                .environment(\.turnErrorSignIn, { [vm] in vm.openSignIn(vm.provider(of: agentID), origin: .agentCard) })
                // The branch card's column at the thread's right; the transcript keeps its identity.
                .modifier(BranchCardDock(store: model.branch.map { _ in vm.branchCardStore(for: agentID) }, branch: model.branch,
                                         active: model.isVisible))
            } else {
                LiveTerminalPane(
                    session: vm.sessions.session(for: pane, in: tab),
                    isFocused: model.isFocused,
                    isRendering: model.isVisible,
                    onFocusAcquired: { [vm] in vm.focusedPaneID = pane.id },
                    addToMessage: model.threadAgentID.map { agentID in { [vm] in vm.addTerminalSelection($0, to: .local(agentID)) } }
                )
                // A restored terminal stays dormant until its tab shows; showing it is the demand
                // that spawns its shell (visible-first, as the iOS client asks its host).
                .onChange(of: model.isVisible, initial: true) { _, visible in
                    if visible { vm.sessions.activateTerminal(pane, in: tab) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sh.bgWindow)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { [vm] in vm.focusedPaneID = pane.id })
    }
}

/// An agent's only surface. Observes the pane session for exit/failure so a dead pi shows
/// the same placeholder a shell pane would.
struct AgentThreadPane: View {
    var session: TerminalSessionStore.PaneSession
    var store: NativeThreadStore
    var input: ThreadInput? = nil
    let active: Bool
    let isFocused: Bool
    let request: NativeThreadStore.Request
    var preview: NativeThreadStore.Preview? = nil
    var commandKey: String?
    let agentName: String
    var workingDirectory: String?
    var inspectSubagent: ((ChildRun) -> Void)? = nil
    var steerSubagent: ((ChildRun) -> Void)? = nil
    var inspectedRunID: String? = nil
    var review: ((String) -> Void)? = nil
    var turnActions: TurnChangesActions? = nil
    /// Retry for a pi that stopped, before it served or on its own after (true: start a new conversation).
    var restartPi: ((Bool) -> Void)? = nil
    /// The line or card at the end of the thread, and what its buttons do.
    var authNotice: ThreadAuthNotice? = nil
    var authActions: ThreadAuthActions? = nil
    var slashLogin: SlashLoginActions? = nil
    /// A design's chat (`ThreadView.designChat`).
    var designChat = false

    var body: some View {
        // The placeholder cross-fades in when pi dies; connecting → live changes nothing here, nor
        // does a pi that stopped: its thread says why.
        ZStack {
            switch session.phase {
            case .connecting, .live, .stopped:
                ThreadView(store: store, active: active, isFocused: isFocused, request: request, preview: preview, commandKey: commandKey,
                           agentName: agentName, workingDirectory: workingDirectory, inspectSubagent: inspectSubagent,
                           steerSubagent: steerSubagent, inspectedRunID: inspectedRunID, review: review, turnActions: turnActions,
                           restartPi: restartPi, authNotice: authNotice, authActions: authActions, slashLogin: designChat ? nil : slashLogin,
                           designChat: designChat, allowsLocalFiles: true, retainedInput: input)
            case .failed(let reason):
                PanePlaceholder(text: "session unavailable · \(reason)")
                    .shTransition(.content)
            case .exited(let code):
                PanePlaceholder(text: code.map { "session exited (\($0))" } ?? "session exited")
                    .shTransition(.content)
            }
        }
        .shAnimation(.content, value: session.phase.isRunning)
    }
}

extension TerminalSessionStore.PaneSession.Phase {
    /// Connecting or live: the session's view is up (a thread, a terminal surface). A stopped
    /// agent's thread stays up too.
    var isRunning: Bool {
        switch self {
        case .connecting, .live, .stopped: true
        case .failed, .exited: false
        }
    }
}

struct LiveTerminalPane: View {
    var session: TerminalSessionStore.PaneSession
    let isFocused: Bool
    /// False for a mounted-but-hidden pane, which keeps its surface but must
    /// stop running a render loop.
    var isRendering: Bool = true
    var onFocusAcquired: (() -> Void)? = nil
    /// Puts a selection in the thread's composer; nil where the layout has no thread.
    var addToMessage: ((String) -> Void)? = nil

    var body: some View {
        // A hidden restored pane mounts its surface only on first demand. Once activated,
        // it stays mounted across selection changes and connecting → live transitions.
        if session.isDormant {
            PanePlaceholder(text: "starting shell…")
        } else {
            ZStack {
                switch session.phase {
                case .connecting, .live:
                    ZStack(alignment: .topLeading) {
                        AppTerminalView(model: session.terminal, isFocused: isFocused, isRendering: isRendering)
                        if case .connecting = session.phase {
                            PanePlaceholder(text: "starting session…")
                                .allowsHitTesting(false)
                                .shTransition(.content)
                        }
                        if let addToMessage {
                            TerminalSelectionOverlay(terminal: session.terminal, add: addToMessage)
                        }
                    }
                case .failed(let reason):
                    PanePlaceholder(text: "session unavailable · \(reason)")
                        .shTransition(.content)
                case .exited(let code):
                    PanePlaceholder(text: code.map { "session exited (\($0))" } ?? "session exited")
                        .shTransition(.content)
                case .stopped:
                    // Only an agent's own pane stops; a shell never does.
                    PanePlaceholder(text: "session stopped")
                        .shTransition(.content)
                }
            }
            .shAnimation(.content, value: session.phase)
            .onAppear { session.terminal.onFocusAcquired = onFocusAcquired }
            .onDisappear { session.terminal.onFocusAcquired = nil }
        }
    }
}

// MARK: Remote layout

/// What one remote thread's layout shows, as plain values the pane resolves once per body
/// (`Resolver`): the layout reads nothing observable, so a host's push or a change elsewhere in
/// the view model that leaves these alone reruns none of it, the thread included. Whatever
/// assumes the layout is on screen reads `isVisible`, which is always true on the overlay.
struct RemoteLayoutModel: Equatable {
    /// The layout's thread: the host's agent in it, and its pane.
    struct Thread: Equatable {
        let paneID: PaneID
        let agentName: String
        /// The thread's folder on the host: the hook glyph counts that host's hooks there.
        let cwd: String
        /// Where it works, for the branch card beside the transcript; only This Mac's threads have one.
        var branch: AgentBranchLabel? = nil
    }

    let ref: RemoteAgentRef
    /// By identity, for actions and pane sessions; never for its observed state.
    let connection: RemoteHostStore.Connection
    let hostName: String
    let isVisible: Bool
    /// The agent's layout, or the host's utility tab while it is inspected.
    let tab: Tab
    /// Nil in a utility tab.
    let thread: Thread?
    /// The focused pane while the layout is on screen and nothing covers the window.
    let focusedPaneID: PaneID?
    /// The subagent the side pane inspects, over its tabs.
    let inspectingRunID: String?
    /// The side pane's tab while it is open, and the tabs pi opened something in.
    var sideTab: SidePaneTab?
    var sideNews: Set<SidePaneTab> = []
    /// The side pane over the whole layout (ChangesWide).
    var sideMaximized = false
    /// The Changes tab's review, by identity; nil where the host carries it as a leaf.
    let review: ReviewSession?
    /// Where a review leaf of an older host's layout reads its review: this agent, while it is on screen.
    let hostReviewTarget: RemoteAgentRef?
    /// The terminal panel under the thread, and its height.
    var terminal = TerminalPanels.Panel()
    var terminalHeight: CGFloat = AppLayout.terminalPanelHeight
    /// The thread's state while the panel is maximized over it, for its folded line; nil
    /// otherwise, and while hidden, so a status report reruns no other layout.
    var foldedState: AgentState?
    /// The transport a terminal leaf asks its host to start over, while it may: on screen, past
    /// Settings, connected, and the host starts terminals.
    let terminalStart: UUID?
    var supportsChanges = false
    /// References to the host's designs, by identity; nil where the host or the thread has none.
    let designReferences: DesignReferenceChips?

    static func == (a: RemoteLayoutModel, b: RemoteLayoutModel) -> Bool {
        let same = a.ref == b.ref && a.connection === b.connection && a.hostName == b.hostName && a.isVisible == b.isVisible
            && a.tab == b.tab && a.thread == b.thread && a.focusedPaneID == b.focusedPaneID
        let side = a.inspectingRunID == b.inspectingRunID && a.sideTab == b.sideTab && a.sideNews == b.sideNews
            && a.sideMaximized == b.sideMaximized && a.review === b.review && a.hostReviewTarget == b.hostReviewTarget
        let panel = a.terminal == b.terminal && a.terminalHeight == b.terminalHeight && a.foldedState == b.foldedState
            && a.terminalStart == b.terminalStart
        return same && side && panel && a.supportsChanges == b.supportsChanges && a.designReferences === b.designReferences
    }
}

/// What a remote agent's pane draws: its layout, or what stands in for it.
enum RemotePresentation: Equatable {
    case layout(RemoteLayoutModel)
    /// The agent draws a design of the host's: its canvas beside the agent's chat.
    case design(RemoteDesignRef, agent: RemoteAgentRef, name: String, threadPaneID: PaneID?)
    /// The host was connected earlier and is being reached again.
    case away(host: String, hostID: UUID, lastSeen: Date, phase: RemoteHostStore.Phase.Kind)
    case placeholder(String, phase: RemoteHostStore.Phase.Kind)

    /// What the pane cross-fades on: the connection's phase, as when the pane read it.
    var kind: RemoteHostStore.Phase.Kind {
        switch self {
        case .layout, .design: .connected
        case .away(_, _, _, let phase), .placeholder(_, let phase): phase
        }
    }
}

extension RemoteLayoutModel {
    /// A host, as the pane sees it.
    struct Host {
        let connection: RemoteHostStore.Connection
        var name: String
        var phase: RemoteHostStore.Phase
        var lastSeen: Date?
        var state: ShepherdState
        var supportsChanges = false
        /// The transport a terminal start goes over, where the host starts terminals.
        var terminalTransport: UUID?
        /// The background host on this Mac: it checks out on this machine.
        var isThisMac = false
    }

    /// This Mac's side of the pane: the selection, the panes beside the thread, focus.
    struct Screen {
        var isVisible = true
        /// The host's utility tab stands in for the agent's layout, and which tab it is.
        var inspecting = false
        var inspectorTab: TabID?
        /// The host's design the agent draws, where it draws one.
        var drawnDesign: DesignID?
        var focusedPaneID: PaneID?
        /// Settings, the gallery or the palette covers the window; Settings alone holds terminals back.
        var covered = false
        var settingsShown = false
        var inspectingRunID: String?
        /// The side pane's tab while it is open, and the tabs pi opened something in.
        var sideTab: SidePaneTab?
        var sideNews: Set<SidePaneTab> = []
        var sideMaximized = false
        var review: ReviewSession?
        /// The terminal panel of a layout.
        var panel: (TabID) -> TerminalPanels.Panel = { _ in TerminalPanels.Panel() }
        var terminalHeight: CGFloat = AppLayout.terminalPanelHeight
        var designReferences: DesignReferenceChips?
    }

    /// What the pane of `ref` draws. A hidden layout keeps its place whatever its host does: the
    /// banner and the placeholders are for a layout on screen.
    @MainActor
    static func presentation(ref: RemoteAgentRef, host: Host, screen: Screen) -> RemotePresentation {
        let phase = host.phase.kind
        let visible = screen.isVisible
        if visible {
            if HostAway.reconnecting(host.phase, lastSeen: host.lastSeen), let lastSeen = host.lastSeen {
                return .away(host: host.name, hostID: host.connection.id, lastSeen: lastSeen, phase: phase)
            }
            switch host.phase {
            case .connected: break
            case .connecting: return .placeholder("connecting to \(host.name)…", phase: phase)
            case .failed(let failure): return .placeholder(failure.message(host: host.name), phase: phase)
            case .disconnected: return .placeholder("\(host.name) disconnected", phase: phase)
            }
        }
        let missing = RemotePresentation.placeholder("agent has no layout on \(host.name)", phase: phase)
        guard let agent = host.state.agents.first(where: { $0.id == ref.agentID }) else { return missing }
        if !screen.inspecting, let design = screen.drawnDesign {
            return .design(RemoteDesignRef(hostID: ref.hostID, designID: design), agent: ref, name: agent.name, threadPaneID: agent.paneID)
        }
        let tabID = screen.inspecting ? screen.inspectorTab ?? agent.tabID : agent.tabID
        guard let tab = host.state.tabs.first(where: { $0.id == tabID }) else { return missing }

        let own = host.state.agents.filter { $0.tabID == tab.id }
        let thread = tab.layout.leaves.lazy.compactMap { leaf in
            primaryAgent(in: tab, pane: leaf, agents: own).map {
                Thread(paneID: leaf.id, agentName: $0.name, cwd: leaf.cwd, branch: host.isThisMac ? AgentBranchLabel(agent: $0) : nil)
            }
        }.first
        let panel = screen.panel(tab.id)
        let hasThread = thread != nil
        return .layout(RemoteLayoutModel(
            ref: ref, connection: host.connection, hostName: host.name, isVisible: visible, tab: tab, thread: thread,
            focusedPaneID: visible && !screen.covered ? screen.focusedPaneID : nil,
            inspectingRunID: hasThread ? screen.inspectingRunID : nil,
            sideTab: hasThread ? screen.sideTab : nil,
            sideNews: hasThread && screen.sideTab != nil ? screen.sideNews : [],
            sideMaximized: screen.sideMaximized,
            // A review a host layout still carries as a leaf (older hosts) renders there instead.
            review: hasThread ? screen.review.flatMap { $0.hostReviewPane ? nil : $0 } : nil,
            hostReviewTarget: visible ? ref : nil,
            terminal: panel, terminalHeight: screen.terminalHeight,
            foldedState: visible && panel.shown && panel.maximized ? AgentState(agent.status) : nil,
            terminalStart: visible && !screen.settingsShown && host.phase == .connected ? host.terminalTransport : nil,
            supportsChanges: host.supportsChanges, designReferences: screen.designReferences))
    }

    /// Gathers the view model's values once per body, and resolves a pane's presentation from them.
    @MainActor
    struct Resolver {
        private let vm: ShepherdViewModel
        private let connections: [RemoteHostStore.Connection]
        private let inspecting: RemoteAgentRef?
        private let inspectorTabs: [RemoteAgentRef: TabID]
        private let panes: RightPaneState
        private let reviews: [RemoteAgentRef: ReviewSession]
        private let terminals: TerminalPanels
        private let focusedPaneID: PaneID?
        private let covered: Bool
        private let settingsShown: Bool

        init(vm: ShepherdViewModel) {
            self.vm = vm
            connections = vm.remoteHosts.connections
            inspecting = vm.remoteInspectingAgent
            inspectorTabs = vm.remoteInspectorTabs
            panes = vm.subagentInspector
            reviews = vm.remoteReviews
            terminals = vm.terminalPanels
            focusedPaneID = vm.remoteFocusedPaneID
            covered = vm.showSettings || vm.showComponentGallery || vm.showCommandPalette
            settingsShown = vm.showSettings
        }

        /// Nil when the host is gone.
        func presentation(for ref: RemoteAgentRef, isVisible: Bool = true) -> RemotePresentation? {
            guard let connection = connections.first(where: { $0.id == ref.hostID }) else { return nil }
            let owner = SidePaneOwner.remote(ref)
            let isInspecting = inspecting == ref
            let sideTab = panes.open.contains(owner) ? panes.tab(for: owner) : nil
            let terminals = terminals
            let host = Host(connection: connection, name: connection.config.name, phase: connection.phase, lastSeen: connection.lastSeen,
                            state: connection.state, supportsChanges: connection.supportsChanges,
                            terminalTransport: connection.supportsTerminalStart ? connection.transportID : nil,
                            isThisMac: connection.isThisMac)
            let screen = Screen(
                isVisible: isVisible, inspecting: isInspecting, inspectorTab: inspectorTabs[ref],
                drawnDesign: isInspecting ? nil : vm.remoteDesign(drawnBy: ref)?.design.id,
                focusedPaneID: focusedPaneID, covered: covered, settingsShown: settingsShown,
                inspectingRunID: panes.remoteRuns[ref], sideTab: sideTab, sideNews: panes.news[owner] ?? [],
                sideMaximized: panes.maximized.contains(owner), review: reviews[ref],
                panel: { terminals.panel(TerminalPanelKey(host: ref.hostID, tab: $0)) }, terminalHeight: terminals.height,
                designReferences: vm.remoteDesignReferenceChips(for: ref))
            return RemoteLayoutModel.presentation(ref: ref, host: host, screen: screen)
        }
    }
}

/// An agent on a remote host: its native thread served by the host, plus any auxiliary
/// shell panes in its layout streamed over that host's connection.
struct RemoteAgentPane: View {
    var vm: ShepherdViewModel
    let ref: RemoteAgentRef

    var body: some View {
        // Resolved once: a push from the host reruns this, and everything under it only when
        // a value it draws changed.
        if let presentation = RemoteLayoutModel.Resolver(vm: vm).presentation(for: ref) {
            RemoteAgentPaneContent(vm: vm, presentation: presentation)
                .equatable()
        } else {
            PanePlaceholder(text: "remote host removed")
        }
    }
}

private struct RemoteAgentPaneContent: View, Equatable {
    var vm: ShepherdViewModel
    let presentation: RemotePresentation

    static func == (a: RemoteAgentPaneContent, b: RemoteAgentPaneContent) -> Bool {
        a.vm === b.vm && a.presentation == b.presentation
    }

    /// Connecting, unreachable, and disconnected placeholders cross-fade with the layout as the
    /// connection changes; switching to the host's inspector tab (`.id(tab.id)`) stays instant.
    var body: some View {
        ZStack {
            switch presentation {
            // One banner through every try (connecting, then waiting out the backoff), so it
            // never flickers between them.
            case .away(let host, let hostID, let lastSeen, _):
                HostAwayBanner(name: host, lastSeen: lastSeen) {
                    vm.remoteHosts.reconnect(id: hostID)
                }
                .shTransition(.content)
            case .design(let design, let agent, let name, let threadPaneID):
                RemoteDesignLayoutView(vm: vm, ref: design, agent: agent, agentName: name, threadPaneID: threadPaneID)
                    .id(design.designID)
            case .layout(let model):
                RemoteAgentLayoutView(vm: vm, model: model)
                    .equatable()
                    .id(model.tab.id)
            case .placeholder(let text, let phase):
                PanePlaceholder(text: text)
                    .shTransition(.content)
                    .id(phase)
            }
        }
        .shAnimation(.content, value: presentation.kind)
    }
}

/// A remote agent's layout with its side pane docked beside the whole layout, as
/// `AgentLayoutView` does locally. The host's inspector tab (a utility terminal) has none. It
/// reads only its model; `vm` is for actions.
private struct RemoteAgentLayoutView: View, Equatable {
    var vm: ShepherdViewModel
    let model: RemoteLayoutModel

    static func == (a: RemoteAgentLayoutView, b: RemoteAgentLayoutView) -> Bool {
        a.vm === b.vm && a.model == b.model
    }

    var body: some View {
        let _ = SHRenderProbe.tick("layout.remoteLayout")
        let ref = model.ref
        let owner = SidePaneOwner.remote(ref)
        let inspecting = model.inspectingRunID
        let sideTab = model.sideTab
        RightPaneSplit(state: vm.subagentInspector, showPane: inspecting != nil || sideTab != nil,
                       maximized: inspecting == nil && model.sideMaximized) {
            RemotePaneTreeView(vm: vm, model: model)
        } pane: {
            if let thread = model.thread {
                let store = vm.remoteThreadStores.store(for: ref)
                RightPaneSlot(showing: inspecting.map { .inspector(runID: $0) } ?? .tab(sideTab ?? .changes, (sideTab ?? .changes) == .changes ? model.review?.id : nil)) {
                    if let inspecting {
                        SubagentInspector(store: store, runID: inspecting, active: model.isVisible, close: { [vm] in
                            vm.closeInspector(owner)
                        }, select: { [vm, ref] in vm.subagentInspector.remoteRuns[ref] = $0.runID }, fork: nil,
                        review: { [vm, ref] in vm.openRemoteReview(ref, path: $0) },
                        focusSteer: vm.subagentInspector.steerRun == inspecting, steerFocused: { [vm] in vm.subagentInspector.steerRun = nil })
                        // The inspector keys its run itself, so a run switch nudges in from its side.
                        .shTransition(.content)
                    } else if let sideTab {
                        SidePaneView(vm: vm, owner: owner, tab: sideTab, news: model.sideNews, review: model.review, store: store,
                                     maximized: model.sideMaximized, active: model.isVisible,
                                     inspect: { [vm, ref] in vm.subagentInspector.remoteRuns[ref] = $0.runID })
                            .shTransition(.content)
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { [vm] in vm.remoteFocusedPaneID = thread.paneID })
            }
        }
    }
}

/// A remote layout drawn like a local one: every leaf a direct child of one ZStack keyed by pane
/// ID, so a tab switch or a hide never rebuilds a terminal.
private struct RemotePaneTreeView: View {
    var vm: ShepherdViewModel
    let model: RemoteLayoutModel
    @State private var liveHeight: CGFloat?

    private var tab: Tab { model.tab }
    private var node: PaneNode { model.tab.layout }
    private var containerSpace: String { "remote-split-\(tab.id)" }

    var body: some View {
        if let thread = model.thread?.paneID, node.contains(thread) {
            panel(thread: thread)
        } else {
            tree
        }
    }

    /// The thread with its terminal panel under it, as a local layout has. Only the terminals on
    /// screen are mounted: a remote terminal attaches while it shows (its grid counts toward the
    /// host's smallest-viewer size), and the host replays it when it comes back.
    private func panel(thread: PaneID) -> some View {
        let key = TerminalPanelKey(host: model.ref.hostID, tab: tab.id)
        let panel = model.terminal
        let target = ShepherdViewModel.TerminalTarget(key: key, layout: node, thread: thread, remote: model.ref, focused: model.focusedPaneID)
        return GeometryReader { geo in
            let _ = SHRenderProbe.tick("layout.remotePaneTree")
            let selected = TerminalPanel.selected(TerminalPanel.tabs(in: node, thread: thread), chosen: panel.chosenTab,
                                                  focused: model.focusedPaneID)
            let geometry = terminalPanelGeometry(for: node, thread: thread, selected: selected, shown: panel.shown,
                                                 maximized: panel.maximized, height: liveHeight ?? model.terminalHeight,
                                                 in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves.filter { ($0.shown && model.isVisible) || $0.pane.id == thread }, id: \.pane.id) { leaf in
                    RemotePaneLeafView(vm: vm, model: model, leaf: leaf.pane, hasThread: true, shown: leaf.shown)
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                        .opacity(leaf.shown ? 1 : 0)
                        .allowsHitTesting(leaf.shown)
                        .accessibilityHidden(!leaf.shown)
                }
                TerminalPanelChrome(geometry: geometry, threadTitle: model.thread?.agentName ?? "",
                                    threadState: model.foldedState ?? .idle,
                                    restore: { [vm] in vm.toggleTerminalMaximized() })
                if let bar = geometry.tabBar {
                    TerminalPanelBar(vm: vm, target: target, tabs: geometry.tabs, selected: selected, maximized: panel.maximized,
                                     onScreen: model.isVisible, host: model.hostName)
                        .frame(width: bar.width, height: bar.height)
                        .overlay(alignment: .top) {
                            if !panel.maximized {
                                TerminalPanelDivider(vm: vm, container: geo.size.height, liveHeight: $liveHeight,
                                                     coordinateSpace: containerSpace)
                                    .offset(y: -AppLayout.resizeHandleWidth / 2)
                            }
                        }
                        .offset(x: bar.minX, y: bar.minY)
                        .zIndex(2)
                }
                if let bar = geometry.tabBar {
                    TerminalMenuLayer(vm: vm, target: target, bar: bar, tabs: geometry.tabs)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(3)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .coordinateSpace(.named(containerSpace))
        .modifier(TerminalActivityPoll(vm: vm, key: key, agent: model.ref.agentID, remote: model.ref,
                                       active: model.isVisible && node.leaves.count > 1))
        .onChange(of: node.leaves.map(\.id), initial: true) {
            vm.terminalPanels.reconcile(key, layout: node, thread: thread)
        }
    }

    private var tree: some View {
        GeometryReader { geo in
            let geometry = paneTreeGeometry(for: node, in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    RemotePaneLeafView(vm: vm, model: model, leaf: leaf.pane)
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .coordinateSpace(.named(containerSpace))
    }
}

private struct RemotePaneLeafView: View {
    var vm: ShepherdViewModel
    let model: RemoteLayoutModel
    let leaf: LeafPane
    /// The layout has the agent's thread (not a host's utility terminal): a terminal's
    /// selection can go to it.
    var hasThread = false
    /// The leaf shows in its panel (the thread always does).
    var shown = true

    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    private struct TerminalDemand: Equatable {
        var paneID: PaneID
        var transport: UUID?
        var active: Bool
    }

    /// What the leaf shows, for its cross-fade.
    private enum Showing: Equatable {
        case thread, review, loadingReview, terminal(SessionID), starting
    }

    /// A placeholder fades out as the review or the terminal it stood for arrives; a terminal
    /// surface itself appears at once and never animates.
    var body: some View {
        let thread = model.thread.flatMap { $0.paneID == leaf.id ? $0 : nil }
        let reviewTarget = thread == nil && leaf.isReview == true ? model.hostReviewTarget : nil
        let review = reviewTarget.flatMap { vm.remoteReviews[$0] }.flatMap { $0.paneID == leaf.id ? $0 : nil }
        let terminal: (id: SessionID, pane: RemotePaneSession)? = thread == nil && reviewTarget == nil
            ? leaf.sessionID.flatMap { id in vm.remoteHosts.paneSession(connection: model.connection, sessionID: id).map { (id, $0) } }
            : nil
        let showing: Showing = thread != nil ? .thread : reviewTarget != nil ? (review != nil ? .review : .loadingReview)
            : terminal.map { .terminal($0.id) } ?? .starting
        ZStack {
            if let thread {
                RemoteAgentThreadPane(vm: vm, ref: model.ref, agentName: thread.agentName,
                                      isFocused: shown && model.focusedPaneID == leaf.id,
                                      active: model.isVisible && shown, cwd: thread.cwd,
                                      inspectingRunID: model.inspectingRunID, supportsChanges: model.supportsChanges,
                                      designReferences: model.designReferences)
                    // This Mac's background host checks out on this machine: its threads get the
                    // branch card, as the app's own do.
                    .modifier(BranchCardDock(store: thread.branch.map { _ in vm.branchCardStore(for: model.ref.agentID) },
                                             branch: thread.branch, active: model.isVisible && shown))
            } else if let target = reviewTarget {
                if let review {
                    ReviewPane(session: review, actions: vm.reviewActions(for: review, remote: true), chrome: .header)
                        .shTransition(.content)
                } else {
                    PanePlaceholder(text: "loading host review…")
                        .task { vm.openRemoteHostReview(target, pane: leaf) }
                        .shTransition(.content)
                }
            } else if let terminal {
                RemoteTerminalPane(pane: terminal.pane,
                                   isFocused: model.focusedPaneID == leaf.id,
                                   onFocusAcquired: { [vm, id = leaf.id] in vm.remoteFocusedPaneID = id },
                                   addToMessage: hasThread ? { [vm, ref = model.ref] in vm.addTerminalSelection($0, to: .remote(ref)) } : nil)
                    .id(terminal.id)
                    .onDisappear { [connection = model.connection] in vm.remoteHosts.closePane(connection: connection, sessionID: terminal.id) }
                    .transition(.identity)
            } else {
                PanePlaceholder(text: "starting remote terminal…")
                    .shTransition(.content)
            }
        }
        .shAnimation(.content, value: showing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sh.bgWindow)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { vm.remoteFocusedPaneID = leaf.id })
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: TerminalDemand(paneID: leaf.id, transport: model.terminalStart,
                                 active: visible && shown && scenePhase == .active && model.terminalStart != nil)) {
            guard visible, shown, scenePhase == .active, model.terminalStart != nil, thread == nil, leaf.isReview != true else { return }
            // Bootstrap retains last run's sessionID. Demand must not depend on it being nil.
            do { try await vm.remoteHosts.agentAction(model.ref, action: .startTerminal(paneID: leaf.id)) }
            catch { vm.fail("Couldn’t start the terminal", error) }
        }
    }
}

/// A remote agent's thread. Same view as a local agent's, with requests sent to the host; its
/// right pane docks beside the whole layout (`RemoteAgentLayoutView`). It reads no view model
/// state in its body: what it needs comes in as values, and the closures read the model when called.
struct RemoteAgentThreadPane: View {
    var vm: ShepherdViewModel
    let ref: RemoteAgentRef
    let agentName: String
    let isFocused: Bool
    /// A design's chat (`ThreadView.designChat`).
    var designChat = false
    var active = true
    /// The thread's folder on the host: the hook glyph counts that host's hooks there.
    var cwd: String? = nil
    /// The subagent the side pane inspects: the composer gives it the keyboard.
    var inspectingRunID: String? = nil
    /// The host answers Changes: the thread's turns offer review, undo and redo.
    var supportsChanges = false
    /// References to the host's designs, where it takes them; nil for a design's own chat.
    var designReferences: DesignReferenceChips? = nil

    var body: some View {
        ThreadView(
            store: vm.remoteThreadStores.store(for: ref),
            active: active,
            isFocused: isFocused && inspectingRunID == nil,
            request: { try await vm.remoteHosts.nativeThread(ref, request: $0) },
            commandKey: ThreadCommandCenter.key(remote: ref),
            agentName: agentName,
            inspectSubagent: { run in
                if vm.subagentInspector.remoteRuns[ref] == run.runID {
                    vm.subagentInspector.remoteRuns.removeValue(forKey: ref)
                } else {
                    vm.subagentInspector.remoteRuns[ref] = run.runID
                }
            },
            steerSubagent: { run in
                vm.subagentInspector.remoteRuns[ref] = run.runID
                vm.subagentInspector.steerRun = run.runID
            },
            inspectedRunID: inspectingRunID,
            review: { path in vm.openRemoteReview(ref, path: path) },
            turnActions: supportsChanges ? TurnChangesActions(
                review: { turnID, path in vm.openTurnReview(.remote(ref), turnID: turnID, path: path) },
                undo: { await vm.undoTurn(.remote(ref), turnID: $0) },
                redo: { await vm.redoTurn(.remote(ref), turnID: $0) }) : nil,
            listModels: {
                guard let listing = try? await vm.remoteHosts.listModels(hostID: ref.hostID) else { return .empty }
                let allLevels = vm.remoteHosts.connections.first { $0.id == ref.hostID }?.supportsAllThinkingLevels ?? false
                return await ModelCatalog.derive(listing, hostTakesAllLevels: allLevels)
            },
            designChat: designChat, hookDirectory: cwd, retainedInput: vm.remoteThreadStores.input(for: ref)
        )
        // References to the host's own designs, where it takes them.
        .environment(\.designReferences, designReferences)
        // Its hook rows, proposals and glyph open and count the host's hooks.
        .environment(\.hookPresenter, HookPresenter(model: vm, host: ref.hostID))
    }
}

private struct RemoteTerminalPane: View {
    var pane: RemotePaneSession
    let isFocused: Bool
    var onFocusAcquired: (() -> Void)? = nil
    /// Puts a selection in the thread's composer; nil in a host's utility terminal.
    var addToMessage: ((String) -> Void)? = nil

    var body: some View {
        // As `LiveTerminalPane`: placeholders fade, the surface never moves.
        ZStack {
            switch pane.phase {
            case .connecting, .live:
                ZStack(alignment: .topLeading) {
                    AppTerminalView(model: pane.terminal, isFocused: isFocused, isRendering: true)
                    if case .connecting = pane.phase {
                        PanePlaceholder(text: "attaching…").allowsHitTesting(false)
                            .shTransition(.content)
                    }
                    if let addToMessage {
                        TerminalSelectionOverlay(terminal: pane.terminal, add: addToMessage)
                    }
                }
                .background(Color.sh.bgWindow)
            case .failed(let reason):
                PanePlaceholder(text: "remote session unavailable · \(reason)")
                    .shTransition(.content)
            case .exited(let code):
                PanePlaceholder(text: code.map { "remote session exited (\($0))" } ?? "remote session exited")
                    .shTransition(.content)
            }
        }
        .shAnimation(.content, value: pane.phase)
        .onAppear { pane.terminal.onFocusAcquired = onFocusAcquired }
        .onDisappear { pane.terminal.onFocusAcquired = nil }
    }
}

/// Whether a remote agent's pane says its host is reconnecting (SHStatus): the host was
/// connected earlier this launch and Shepherd is trying it again. A host that never connected, or
/// a failure that won't retry (a refused token, another protocol), keeps its own placeholder.
enum HostAway {
    static func reconnecting(_ phase: RemoteHostStore.Phase, lastSeen: Date?) -> Bool {
        guard lastSeen != nil else { return false }
        switch phase {
        case .connecting: return true
        case .failed(let failure): return failure.retries
        case .connected, .disconnected: return false
        }
    }

    /// "Last seen 3h ago. Remote agents resume when it's back."
    static func message(lastSeen: Date, now: Date = Date()) -> String {
        "Last seen \(InstructionsPresentation.age(lastSeen.timeIntervalSince1970, now: now)). Remote agents resume when it’s back."
    }
}

/// A remote agent's pane while its host is away (SHStatus › A host reconnecting): a running banner
/// with when the host was last seen, and Retry now, which skips the wait before the next try.
struct HostAwayBanner: View {
    let name: String
    let lastSeen: Date
    let retry: () -> Void

    var body: some View {
        // The age moves on by itself ("just now", then "1m ago").
        TimelineView(.periodic(from: .now, by: 60)) { context in
            SHBanner(.running, title: "\(name) reconnecting", message: HostAway.message(lastSeen: lastSeen, now: context.date),
                     systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                Button("Retry now", action: retry)
                    .buttonStyle(.sh(.secondary, size: .s))
            }
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(AppLayout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct PanePlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.sh(.micro, weight: .regular))
            .foregroundStyle(Color.sh.textTertiary)
            .padding(AppLayout.panePlaceholderPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The bar beside a terminal's selection (TerminalPane): Add to message puts it in the thread's
/// composer, Copy copies it. It hangs under the selection's last line at the pane's trailing
/// edge, or over its first line where there is no room below, and goes when the selection does.
struct TerminalSelectionOverlay: View {
    let terminal: AppTerminalModel
    let add: (String) -> Void
    @State private var selection: AppTerminalModel.Selection?
    @State private var barHeight: CGFloat = SH.Height.controlS + 2 * SHTerminalMetrics.selectionBarPadding

    var body: some View {
        GeometryReader { geo in
            if let selection {
                SHTerminalSelectionBar(add: {
                    add(selection.text)
                    self.selection = nil
                }, copy: {
                    terminal.copySelection()
                    self.selection = nil
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, SHTerminalMetrics.selectionBarInset)
                .offset(y: Self.top(selection, barHeight: barHeight, in: geo.size.height))
                .shTransition(.overlay, edge: .top)
            }
        }
        .shAnimation(.overlay, value: selection == nil)
        .onAppear { terminal.onSelectionChange = { selection = $0 } }
        .onDisappear { terminal.onSelectionChange = nil }
    }

    /// Under the selection's last line, else over its first, never outside the pane.
    static func top(_ selection: AppTerminalModel.Selection, barHeight: CGFloat, in height: CGFloat) -> CGFloat {
        let gap = SHTerminalMetrics.selectionBarPadding
        let below = selection.origin.y + CGFloat(selection.lineCount) * selection.lineHeight + gap
        if below + barHeight <= height { return below }
        return max(0, min(height - barHeight, selection.origin.y - barHeight - gap))
    }
}

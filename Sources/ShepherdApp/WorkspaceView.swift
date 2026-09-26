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
    @State private var column = LiveResizeColumn()
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
                AgentLayoutDeck(vm: vm, models: mounted.map { models.model(for: $0) }, frozenSize: frozenSize)
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
            .background(Color.nw.bgWindow)
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
        .background(Color.nw.bgWindow)
        // Window-level file/image drop routing for terminal panes; per-pane
        // SwiftUI .onDrop cannot coexist with permanently mounted hidden
        // layouts (see TerminalDropOverlay.swift).
        .background { AppTerminalDropOverlay() }
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
    var terminalHeight: CGFloat = AppLayout.terminalPanelHeight

    static func == (a: AgentLayoutModel, b: AgentLayoutModel) -> Bool {
        a.tab == b.tab && a.isVisible == b.isVisible && a.thread == b.thread && a.focusedPaneID == b.focusedPaneID
            && a.inspectingRunID == b.inspectingRunID && a.sideTab == b.sideTab && a.sideNews == b.sideNews
            && a.sideMaximized == b.sideMaximized && a.review === b.review
            && a.terminal == b.terminal && a.terminalHeight == b.terminalHeight
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

        init(vm: ShepherdViewModel, visibleTabID: TabID?) {
            terminals = vm.terminalPanels
            self.visibleTabID = visibleTabID
            focusedPaneID = vm.focusedPaneID
            agentsByTab = Dictionary(vm.state.agents.map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
            runs = vm.subagentInspector.runByAgent
            panes = vm.subagentInspector
            reviews = Dictionary(vm.reviewSessions.values.map { ($0.agentID, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func model(for tab: Tab) -> AgentLayoutModel {
            let visible = tab.id == visibleTabID
            let thread = agentsByTab[tab.id].flatMap { agent in
                tab.layout.leaves.first { primaryAgent(in: tab, pane: $0, agents: [agent]) != nil }
                    .map { Thread(agentID: agent.id, paneID: $0.id, agentName: agent.name, piSessionID: agent.effectivePiSessionID) }
            }
            let owner = thread.map { SidePaneOwner.local($0.agentID) }
            return AgentLayoutModel(tab: tab, isVisible: visible, thread: thread, focusedPaneID: visible ? focusedPaneID : nil,
                                    inspectingRunID: thread.flatMap { runs[$0.agentID] },
                                    sideTab: owner.flatMap { panes.open.contains($0) ? panes.tab(for: $0) : nil },
                                    sideNews: owner.flatMap { panes.news[$0] } ?? [],
                                    sideMaximized: owner.map { panes.maximized.contains($0) } ?? false,
                                    review: thread.flatMap { reviews[$0.agentID] },
                                    terminal: terminals.panel(TerminalPanelKey(host: nil, tab: tab.id)),
                                    terminalHeight: terminals.height)
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
        let _ = NWRenderProbe.tick("layout.agentLayout")
        let thread = model.thread
        let inspecting = model.inspectingRunID
        let sideTab = model.sideTab
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
                RightPaneSlot(showing: inspecting.map { .inspector(runID: $0) } ?? .tab(sideTab ?? .changes, model.review?.id)) {
                    if let inspecting {
                        SubagentInspector(store: store, runID: inspecting, active: model.isVisible, close: { [vm] in
                            vm.closeInspector(owner)
                        }, select: { [vm] in vm.subagentInspector.runByAgent[agentID] = $0.runID }, fork: { [vm] run in
                            do { try await vm.forkSubagent(agentID: agentID, run: run); return nil } catch { return String(describing: error) }
                        }, review: { [vm] in vm.openReview(agentID: agentID, path: $0) },
                        focusSteer: vm.subagentInspector.steerRun == inspecting, steerFocused: { [vm] in vm.subagentInspector.steerRun = nil })
                        // The inspector keys its run itself, so a run switch nudges in from its side.
                        .nwTransition(.content)
                    } else if let sideTab {
                        SidePaneView(vm: vm, owner: owner, tab: sideTab, news: model.sideNews, review: model.review, store: store,
                                     maximized: model.sideMaximized)
                            .nwTransition(.content)
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
/// Changing the split tree moves and resizes leaves without remounting their
/// terminal surfaces.
struct PaneTreeView: View {
    var vm: ShepherdViewModel
    /// Everything the tree draws; `vm` is for actions.
    let model: AgentLayoutModel
    @State private var liveRatios: [PaneSplitPath: Double] = [:]
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
    /// a direct child of one ZStack keyed by pane ID, shown or not, so a tab switch, a hide or a
    /// split never remounts a terminal's surface.
    private func panel(thread: AgentLayoutModel.Thread) -> some View {
        let panel = model.terminal
        let target = ShepherdViewModel.TerminalTarget(key: key, layout: tab.layout, thread: thread.paneID, remote: nil,
                                                      focused: model.focusedPaneID)
        return GeometryReader { geo in
            let _ = NWRenderProbe.tick("layout.paneTreeGeo")
            let selected = TerminalPanel.selected(TerminalPanel.tabs(in: tab.layout, thread: thread.paneID), chosen: panel.chosenTab,
                                                  remembering: panel.chosenPanes, focused: model.focusedPaneID)
            let geometry = terminalPanelGeometry(for: tab.layout, thread: thread.paneID, selected: selected, shown: panel.shown,
                                                 maximized: panel.maximized, height: liveHeight ?? model.terminalHeight,
                                                 in: geo.size, liveRatios: liveRatios)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    PaneLeafView(vm: vm, tab: tab, model: leafModel(leaf.pane, shown: leaf.shown))
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                        .opacity(leaf.shown ? 1 : 0)
                        .allowsHitTesting(leaf.shown)
                        .accessibilityHidden(!leaf.shown)
                }
                ForEach(geometry.separators) { separator in
                    PaneSeparatorView(
                        axis: separator.axis, rect: separator.rect, containerRect: separator.containerRect,
                        color: separatorColor(for: separator.node), coordinateSpace: containerSpace,
                        liveRatio: Binding(get: { liveRatios[separator.id] }, set: { liveRatios[separator.id] = $0 }),
                        onCommit: { vm.commitSplitRatio(tabID: tab.id, split: separator.node, ratio: $0) }
                    )
                }
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
                if geometry.tabs.isEmpty, let content = geometry.content {
                    TerminalPanelEmpty(vm: vm, target: target)
                        .frame(width: content.width, height: content.height)
                        .offset(x: content.minX, y: content.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .nwAnimation(.content, value: panel.shown)
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
            let _ = NWRenderProbe.tick("layout.paneTreeGeo")
            let geometry = paneTreeGeometry(for: tab.layout, in: geo.size, liveRatios: liveRatios)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    PaneLeafView(vm: vm, tab: tab, model: leafModel(leaf.pane))
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                }

                ForEach(geometry.separators) { separator in
                    PaneSeparatorView(
                        axis: separator.axis,
                        rect: separator.rect,
                        containerRect: separator.containerRect,
                        color: separatorColor(for: separator.node),
                        coordinateSpace: containerSpace,
                        liveRatio: Binding(
                            get: { liveRatios[separator.id] },
                            set: { liveRatios[separator.id] = $0 }
                        ),
                        onCommit: {
                            vm.commitSplitRatio(tabID: tab.id, split: separator.node, ratio: $0)
                        }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .coordinateSpace(.named(containerSpace))
    }

    private func separatorColor(for split: PaneNode) -> Color {
        paneSeparatorColor(split, focused: model.focusedPaneID)
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
            inspectingRunID: thread == nil ? nil : model.inspectingRunID
        )
    }
}

/// Dividers are 1pt `lineSubtle`, tinted `focusDivider` where they border the focused pane.
@MainActor
func paneSeparatorColor(_ split: PaneNode, focused: PaneID?) -> Color {
    guard let focused, case .split(_, _, let first, let second) = split else { return Color.nw.lineSubtle }
    return first.contains(focused) || second.contains(focused) ? Color.nw.focusDivider : Color.nw.lineSubtle
}

struct PaneSeparatorView: View {
    let axis: SplitAxis
    let rect: CGRect
    let containerRect: CGRect
    let color: Color
    let coordinateSpace: String
    @Binding var liveRatio: Double?
    let onCommit: (Double) -> Void

    var body: some View {
        color
            .frame(width: rect.width, height: rect.height)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? AppLayout.resizeHandleWidth : nil,
                           height: axis == .horizontal ? AppLayout.resizeHandleWidth : nil)
                    .contentShape(Rectangle())
                    .pointerStyle(axis == .vertical ? .columnResize : .rowResize)
                    .gesture(dragGesture)
            }
            .offset(x: rect.minX, y: rect.minY)
            // Focus moving between panes tints the divider (`.hover`); a split, a close, or a
            // drag moves it at once, like the panes it divides.
            .animation(nil, value: rect)
            .nwAnimation(.hover, value: color)
            .zIndex(1)
    }

    private var dragGesture: some Gesture {
        // The root coordinate space does not move with the divider. Subtract
        // this split's origin to recover the same local position the nested
        // split view used, without corrupted moving-view translations.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                let span = axis == .vertical ? containerRect.width : containerRect.height
                let origin = axis == .vertical ? containerRect.minX : containerRect.minY
                let position = (axis == .vertical ? value.location.x : value.location.y) - origin
                liveRatio = ShellLayout.splitRatio(position: position, span: span)
            }
            .onEnded { _ in
                if let final = liveRatio {
                    onCommit(final)
                }
                liveRatio = nil
            }
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
    /// The subagent the right pane inspects (`AgentLayoutView`): the thread yields keyboard focus.
    let inspectingRunID: String?
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
                    active: model.isVisible,
                    isFocused: model.isFocused && inspecting == nil,
                    request: { [vm] in try await vm.server.nativeThread(agentID: agentID, request: $0) },
                    preview: model.piSessionID.map { PiSessionFile.previewLoader(sessionID: $0, cwd: pane.cwd) },
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
                        redo: { [vm] in await vm.redoTurn(.local(agentID), turnID: $0) })
                )
            } else {
                LiveTerminalPane(
                    session: vm.sessions.session(for: pane, in: tab),
                    isFocused: model.isFocused,
                    isRendering: model.isVisible
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { [vm] in vm.focusedPaneID = pane.id })
    }
}

/// An agent's only surface. Observes the pane session for exit/failure so a dead pi shows
/// the same placeholder a shell pane would.
struct AgentThreadPane: View {
    var session: TerminalSessionStore.PaneSession
    var store: NativeThreadStore
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

    var body: some View {
        // The placeholder cross-fades in when pi dies; connecting → live changes nothing here.
        ZStack {
            switch session.phase {
            case .connecting, .live:
                ThreadView(store: store, active: active, isFocused: isFocused, request: request, preview: preview, commandKey: commandKey,
                           agentName: agentName, workingDirectory: workingDirectory, inspectSubagent: inspectSubagent,
                           steerSubagent: steerSubagent, inspectedRunID: inspectedRunID, review: review, turnActions: turnActions)
            case .failed(let reason):
                PanePlaceholder(text: "session unavailable · \(reason)")
                    .nwTransition(.content)
            case .exited(let code):
                PanePlaceholder(text: code.map { "session exited (\($0))" } ?? "session exited")
                    .nwTransition(.content)
            }
        }
        .nwAnimation(.content, value: session.phase.isRunning)
    }
}

extension TerminalSessionStore.PaneSession.Phase {
    /// Connecting or live: the session's view is up (a thread, a terminal surface).
    var isRunning: Bool {
        switch self {
        case .connecting, .live: true
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

    var body: some View {
        // "starting session…" fades off the surface once it is live; a failed or exited
        // session's placeholder cross-fades with it. The surface itself never moves (it is
        // `nwInstant`).
        ZStack {
            switch session.phase {
            case .connecting, .live:
                // Keep one Ghostty view mounted across the connecting → live
                // transition. Replacing it here discards the just-replayed screen.
                ZStack(alignment: .topLeading) {
                    AppTerminalView(model: session.terminal, isFocused: isFocused, isRendering: isRendering)
                    if case .connecting = session.phase {
                        PanePlaceholder(text: "starting session…")
                            .allowsHitTesting(false)
                            .nwTransition(.content)
                    }
                }
            case .failed(let reason):
                PanePlaceholder(text: "session unavailable · \(reason)")
                    .nwTransition(.content)
            case .exited(let code):
                PanePlaceholder(text: code.map { "session exited (\($0))" } ?? "session exited")
                    .nwTransition(.content)
            }
        }
        .nwAnimation(.content, value: session.phase)
    }
}

/// An agent on a remote host: its native thread served by the host, plus any auxiliary
/// shell panes in its layout streamed over that host's connection.
struct RemoteAgentPane: View {
    var vm: ShepherdViewModel
    let ref: RemoteAgentRef

    var body: some View {
        // Resolve connection → agent → bound session on every update; the
        // remote state push that changes any of these re-renders this view.
        if let connection = vm.remoteHosts.connections.first(where: { $0.id == ref.hostID }) {
            RemoteAgentPaneContent(vm: vm, connection: connection, agentID: ref.agentID)
        } else {
            PanePlaceholder(text: "remote host removed")
        }
    }
}

private struct RemoteAgentPaneContent: View {
    var vm: ShepherdViewModel
    var connection: RemoteHostStore.Connection
    let agentID: AgentID

    /// Connecting, unreachable, and disconnected placeholders cross-fade with the layout as the
    /// connection changes; switching to the host's inspector tab (`.id(tab.id)`) stays instant.
    var body: some View {
        let away = HostAway.reconnecting(connection.phase, lastSeen: connection.lastSeen)
        ZStack {
            // One banner through every try (connecting, then waiting out the backoff), so it
            // never flickers between them.
            if away {
                HostAwayBanner(name: connection.config.name, lastSeen: connection.lastSeen ?? Date()) {
                    vm.remoteHosts.reconnect(id: connection.id)
                }
                .nwTransition(.content)
            } else {
                switch connection.phase {
                case .connected:
                    if let agent = connection.state.agents.first(where: { $0.id == agentID }),
                       let tab = connection.state.tabs.first(where: {
                           let ref = RemoteAgentRef(hostID: connection.id, agentID: agentID)
                           return $0.id == (vm.remoteInspectingAgent == ref ? vm.remoteInspectorTabs[ref] ?? agent.tabID : agent.tabID)
                       }) {
                        RemoteAgentLayoutView(
                            vm: vm,
                            connection: connection,
                            ref: RemoteAgentRef(hostID: connection.id, agentID: agentID),
                            tab: tab
                        )
                        .id(tab.id)
                    } else {
                        PanePlaceholder(text: "agent has no layout on \(connection.config.name)")
                            .nwTransition(.content)
                    }
                case .connecting:
                    PanePlaceholder(text: "connecting to \(connection.config.name)…")
                        .nwTransition(.content)
                case .failed(let failure):
                    PanePlaceholder(text: failure.message(host: connection.config.name))
                        .nwTransition(.content)
                case .disconnected:
                    PanePlaceholder(text: "\(connection.config.name) disconnected")
                        .nwTransition(.content)
                }
            }
        }
        .nwAnimation(.content, value: connection.phase.kind)
    }
}

/// A remote agent's layout with its side pane docked beside the whole layout, as
/// `AgentLayoutView` does locally. The host's inspector tab (a utility terminal) has none.
private struct RemoteAgentLayoutView: View {
    var vm: ShepherdViewModel
    var connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let tab: Tab

    var body: some View {
        let threadPaneID = tab.layout.leaves.first { primaryAgent(in: tab, pane: $0, agents: connection.state.agents) != nil }?.id
        let owner = SidePaneOwner.remote(ref)
        let panes = vm.subagentInspector
        let inspecting = threadPaneID == nil ? nil : panes.remoteRuns[ref]
        let sideTab = threadPaneID != nil && panes.open.contains(owner) ? panes.tab(for: owner) : nil
        // A review a host layout still carries as a leaf (older hosts) renders there instead.
        let review = threadPaneID == nil ? nil : vm.remoteReviews[ref].flatMap { $0.hostReviewPane ? nil : $0 }
        RightPaneSplit(state: panes, showPane: inspecting != nil || sideTab != nil,
                       maximized: inspecting == nil && panes.maximized.contains(owner)) {
            RemotePaneTreeView(vm: vm, connection: connection, ref: ref, tab: tab, node: tab.layout, thread: threadPaneID)
        } pane: {
            if let threadPaneID {
                let store = vm.remoteThreadStores.store(for: ref)
                RightPaneSlot(showing: inspecting.map { .inspector(runID: $0) } ?? .tab(sideTab ?? .changes, review?.id)) {
                    if let inspecting {
                        SubagentInspector(store: store, runID: inspecting, active: true, close: { [vm] in
                            vm.closeInspector(owner)
                        }, select: { [vm, ref] in vm.subagentInspector.remoteRuns[ref] = $0.runID }, fork: nil,
                        review: { [vm, ref] in vm.openRemoteReview(ref, path: $0) },
                        focusSteer: vm.subagentInspector.steerRun == inspecting, steerFocused: { [vm] in vm.subagentInspector.steerRun = nil })
                        // The inspector keys its run itself, so a run switch nudges in from its side.
                        .nwTransition(.content)
                    } else if let sideTab {
                        SidePaneView(vm: vm, owner: owner, tab: sideTab, news: panes.news[owner] ?? [], review: review, store: store,
                                     maximized: panes.maximized.contains(owner))
                            .nwTransition(.content)
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { [vm] in vm.remoteFocusedPaneID = threadPaneID })
            }
        }
    }
}

/// A remote layout drawn like a local one: every leaf a direct child of one ZStack keyed by pane
/// ID, so a split moves and resizes panes instead of rebuilding them.
private struct RemotePaneTreeView: View {
    var vm: ShepherdViewModel
    var connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let tab: Tab
    let node: PaneNode
    /// The agent's thread pane; nil for the host's utility terminal, drawn as its own splits.
    var thread: PaneID? = nil
    @State private var liveRatios: [PaneSplitPath: Double] = [:]
    @State private var liveHeight: CGFloat?

    private var containerSpace: String { "remote-split-\(tab.id)" }

    var body: some View {
        if let thread, node.contains(thread) {
            panel(thread: thread)
        } else {
            tree
        }
    }

    /// The thread with its terminal panel under it, as a local layout has. Only the panes on
    /// screen are mounted: a remote terminal attaches while it shows (its grid counts toward the
    /// host's smallest-viewer size), and the host replays it when it comes back.
    private func panel(thread: PaneID) -> some View {
        let key = TerminalPanelKey(host: connection.id, tab: tab.id)
        let panel = vm.terminalPanels.panel(key)
        let target = ShepherdViewModel.TerminalTarget(key: key, layout: node, thread: thread, remote: ref, focused: vm.remoteFocusedPaneID)
        return GeometryReader { geo in
            let selected = TerminalPanel.selected(TerminalPanel.tabs(in: node, thread: thread), chosen: panel.chosenTab,
                                                  remembering: panel.chosenPanes, focused: vm.remoteFocusedPaneID)
            let geometry = terminalPanelGeometry(for: node, thread: thread, selected: selected, shown: panel.shown,
                                                 maximized: panel.maximized, height: liveHeight ?? vm.terminalPanels.height,
                                                 in: geo.size, liveRatios: liveRatios)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves.filter(\.shown), id: \.pane.id) { leaf in
                    RemotePaneLeafView(vm: vm, connection: connection, ref: ref, tab: tab, leaf: leaf.pane)
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                }
                ForEach(geometry.separators) { separator in
                    PaneSeparatorView(
                        axis: separator.axis, rect: separator.rect, containerRect: separator.containerRect,
                        color: paneSeparatorColor(separator.node, focused: vm.remoteFocusedPaneID), coordinateSpace: containerSpace,
                        liveRatio: Binding(get: { liveRatios[separator.id] }, set: { liveRatios[separator.id] = $0 }),
                        onCommit: { vm.commitRemoteSplitRatio(ref: ref, split: separator.node, ratio: $0) }
                    )
                }
                if let bar = geometry.tabBar {
                    TerminalPanelBar(vm: vm, target: target, tabs: geometry.tabs, selected: selected, maximized: panel.maximized,
                                     onScreen: true, host: connection.config.name)
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
                if geometry.tabs.isEmpty, let content = geometry.content {
                    TerminalPanelEmpty(vm: vm, target: target)
                        .frame(width: content.width, height: content.height)
                        .offset(x: content.minX, y: content.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .coordinateSpace(.named(containerSpace))
        .modifier(TerminalActivityPoll(vm: vm, key: key, agent: ref.agentID, remote: ref, active: node.leaves.count > 1))
        .onChange(of: node.leaves.map(\.id), initial: true) {
            vm.terminalPanels.reconcile(key, layout: node, thread: thread)
        }
    }

    private var tree: some View {
        GeometryReader { geo in
            let geometry = paneTreeGeometry(for: node, in: geo.size, liveRatios: liveRatios)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    RemotePaneLeafView(vm: vm, connection: connection, ref: ref, tab: tab, leaf: leaf.pane)
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                }
                ForEach(geometry.separators) { separator in
                    PaneSeparatorView(
                        axis: separator.axis,
                        rect: separator.rect,
                        containerRect: separator.containerRect,
                        color: paneSeparatorColor(separator.node, focused: vm.remoteFocusedPaneID),
                        coordinateSpace: containerSpace,
                        liveRatio: Binding(
                            get: { liveRatios[separator.id] },
                            set: { liveRatios[separator.id] = $0 }
                        ),
                        onCommit: { vm.commitRemoteSplitRatio(ref: ref, split: separator.node, ratio: $0) }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .coordinateSpace(.named(containerSpace))
    }
}

private struct RemotePaneLeafView: View {
    var vm: ShepherdViewModel
    var connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let tab: Tab
    let leaf: LeafPane

    /// What the leaf shows, for its cross-fade.
    private enum Showing: Equatable {
        case thread, review, loadingReview, terminal(SessionID), starting
    }

    /// A placeholder fades out as the review or the terminal it stood for arrives; a terminal
    /// surface itself appears at once and never animates.
    var body: some View {
        let agent = primaryAgent(in: tab, pane: leaf, agents: connection.state.agents)
        let reviewTarget = agent == nil && leaf.isReview == true ? vm.selectedRemoteAgent : nil
        let review = reviewTarget.flatMap { vm.remoteReviews[$0] }.flatMap { $0.paneID == leaf.id ? $0 : nil }
        let terminal: (id: SessionID, pane: RemotePaneSession)? = agent == nil && reviewTarget == nil
            ? leaf.sessionID.flatMap { id in vm.remoteHosts.paneSession(connection: connection, sessionID: id).map { (id, $0) } }
            : nil
        let showing: Showing = agent != nil ? .thread : reviewTarget != nil ? (review != nil ? .review : .loadingReview)
            : terminal.map { .terminal($0.id) } ?? .starting
        ZStack {
            if let agent {
                RemoteAgentThreadPane(vm: vm, ref: ref, agentName: agent.name, isFocused: vm.remoteFocusedPaneID == leaf.id)
            } else if let target = reviewTarget {
                if let review {
                    ReviewPane(session: review, actions: vm.reviewActions(for: review, remote: true), chrome: .header)
                        .nwTransition(.content)
                } else {
                    PanePlaceholder(text: "loading host review…")
                        .task { vm.openRemoteHostReview(target, pane: leaf) }
                        .nwTransition(.content)
                }
            } else if let terminal {
                RemoteTerminalPane(pane: terminal.pane, isFocused: vm.remoteFocusedPaneID == leaf.id)
                    .id(terminal.id)
                    .onDisappear { vm.remoteHosts.closePane(connection: connection, sessionID: terminal.id) }
                    .transition(.identity)
            } else {
                PanePlaceholder(text: "starting remote pane…")
                    .nwTransition(.content)
            }
        }
        .nwAnimation(.content, value: showing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { vm.remoteFocusedPaneID = leaf.id })
    }
}

/// A remote agent's thread. Same view as a local agent's, with requests sent to the host; its
/// right pane docks beside the whole layout (`RemoteAgentLayoutView`).
private struct RemoteAgentThreadPane: View {
    var vm: ShepherdViewModel
    let ref: RemoteAgentRef
    let agentName: String
    let isFocused: Bool

    var body: some View {
        let inspecting = vm.subagentInspector.remoteRuns[ref]
        ThreadView(
            store: vm.remoteThreadStores.store(for: ref),
            active: true,
            isFocused: isFocused && inspecting == nil,
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
            inspectedRunID: inspecting,
            review: { path in vm.openRemoteReview(ref, path: path) },
            turnActions: vm.remoteHosts.connections.first(where: { $0.id == ref.hostID })?.supportsChanges == true ? TurnChangesActions(
                review: { turnID, path in vm.openTurnReview(.remote(ref), turnID: turnID, path: path) },
                undo: { await vm.undoTurn(.remote(ref), turnID: $0) },
                redo: { await vm.redoTurn(.remote(ref), turnID: $0) }) : nil,
            listModels: {
                guard let listing = try? await vm.remoteHosts.listModels(hostID: ref.hostID) else { return .empty }
                let allLevels = vm.remoteHosts.connections.first { $0.id == ref.hostID }?.supportsAllThinkingLevels ?? false
                return await ModelCatalog.derive(listing, hostTakesAllLevels: allLevels)
            }
        )
    }
}

private struct RemoteTerminalPane: View {
    var pane: RemotePaneSession
    let isFocused: Bool

    var body: some View {
        // As `LiveTerminalPane`: placeholders fade, the surface never moves.
        ZStack {
            switch pane.phase {
            case .connecting, .live:
                ZStack(alignment: .topLeading) {
                    AppTerminalView(model: pane.terminal, isFocused: isFocused, isRendering: true)
                    if case .connecting = pane.phase {
                        PanePlaceholder(text: "attaching…").allowsHitTesting(false)
                            .nwTransition(.content)
                    }
                }
                .background(Color.nw.bgWindow)
            case .failed(let reason):
                PanePlaceholder(text: "remote session unavailable · \(reason)")
                    .nwTransition(.content)
            case .exited(let code):
                PanePlaceholder(text: code.map { "remote session exited (\($0))" } ?? "remote session exited")
                    .nwTransition(.content)
            }
        }
        .nwAnimation(.content, value: pane.phase)
    }
}

/// Whether a remote agent's pane says its host is reconnecting (NWStatus): the host was
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

/// A remote agent's pane while its host is away (NWStatus › A host reconnecting): a running banner
/// with when the host was last seen, and Retry now, which skips the wait before the next try.
struct HostAwayBanner: View {
    let name: String
    let lastSeen: Date
    let retry: () -> Void

    var body: some View {
        // The age moves on by itself ("just now", then "1m ago").
        TimelineView(.periodic(from: .now, by: 60)) { context in
            NWBanner(.running, title: "\(name) reconnecting", message: HostAway.message(lastSeen: lastSeen, now: context.date),
                     systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                Button("Retry now", action: retry)
                    .buttonStyle(.nw(.secondary, size: .s))
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
            .font(Font.nw(.micro, weight: .regular))
            .foregroundStyle(Color.nw.textTertiary)
            .padding(AppLayout.panePlaceholderPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

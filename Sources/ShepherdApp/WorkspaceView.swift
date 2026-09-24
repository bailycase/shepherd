import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

struct WorkspaceView: View {
    var vm: ShepherdViewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Every mounted layout stays mounted; switching agents only
                // changes which one is visible. Unmounting would destroy the
                // Ghostty views and force a re-attach + full replay on every
                // switch, which is what made switching flash. Hidden panes
                // keep their surfaces, scrollback, and their process's real
                // grid (see WorkspaceSelection).
                let mounted = vm.mountedTabs
                let visibleTabID = vm.activeTabID
                ForEach(mounted) { tab in
                    let isVisible = tab.id == visibleTabID
                    AgentLayoutView(vm: vm, tab: tab)
                        .id(tab.id)
                        // `opacity(0)`, never a conditional `.hidden()`
                        // branch: `if hidden { … } else { … }` is
                        // ConditionalContent — flipping it changes structural
                        // identity, and SwiftUI destroys and recreates the
                        // whole subtree, ghostty NSView included. That is a
                        // full surface teardown + replay + reflow on every
                        // switch. Opacity keeps identity; the pane's
                        // `isRendering: false` already stops the hidden
                        // surface's drawing via ghostty occlusion, so an
                        // invisible pane costs no GPU time either way.
                        .opacity(isVisible ? 1 : 0)
                        // A hidden pane must not take clicks, keyboard focus,
                        // or VoiceOver from the visible one.
                        .allowsHitTesting(isVisible)
                        .accessibilityHidden(!isVisible)
                        // Nor draw its spinners and glows where no one sees them.
                        .environment(\.nwMotionPaused, !isVisible)
                }

                if let remote = vm.selectedRemoteAgent {
                    RemoteAgentPane(vm: vm, ref: remote)
                        .id(remote)
                }

                // The empty state cross-fades on a layer of its own; the layouts under it still
                // flip at once.
                let empty = visibleTabID == nil && vm.selectedRemoteAgent == nil
                ZStack {
                    if empty {
                        EmptyWorkspace(vm: vm)
                            .nwTransition(.content)
                    }
                }
                .nwAnimation(.content, value: empty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.nw.bgWindow)
        }
        // Every path that changes the active tab lands here: keep parking bookkeeping current.
        .onChange(of: vm.activeTabID, initial: true) { vm.noteActiveTabVisited() }
        .background(Color.nw.bgWindow)
        // Window-level file/image drop routing for terminal panes; per-pane
        // SwiftUI .onDrop cannot coexist with permanently mounted hidden
        // layouts (see TerminalDropOverlay.swift).
        .background { AppTerminalDropOverlay() }
    }
}

/// No agent on screen: a space with no agents yet, or no spaces at all. Its variants cross-fade
/// into one another.
struct EmptyWorkspace: View {
    var vm: ShepherdViewModel
    private var keys: KeybindingsStore { .shared }

    private enum Variant: Equatable {
        case space(SpaceID, hasAgents: Bool)
        case noSpaces
        case noSelection
    }

    private var variant: Variant {
        if let space = vm.selectedSpace { return .space(space.id, hasAgents: vm.state.agents.contains { $0.spaceID == space.id }) }
        return vm.state.spaces.isEmpty ? .noSpaces : .noSelection
    }

    var body: some View {
        ZStack {
            if let space = vm.selectedSpace {
                let hasAgents = vm.state.agents.contains { $0.spaceID == space.id }
                NWEmptyState(Text(hasAgents ? "No agent selected" : "No agents in \(space.name)"),
                             message: hasAgents ? "Pick one in the sidebar, or start another in \(space.name)."
                                                : "Start one to work in \(space.path.abbreviatingWithTilde).") {
                    Button("New agent") { vm.quickCreateAgent(in: space.id) }
                        .buttonStyle(.nw(.primary))
                    NWKeycap(keys.display(.newAgent))
                }
            } else if vm.state.spaces.isEmpty {
                NWEmptyState(Text("No spaces yet"), message: "A space is a project folder your agents work in.") {
                    Button("New space…") { vm.addSpaceFromPanel() }
                        .buttonStyle(.nw(.primary))
                }
            } else {
                NWEmptyState(Text("No agent selected"), message: "Pick one in the sidebar, or start a new one.") {
                    NWKeycap(keys.display(.newAgent))
                }
            }
        }
        .nwContentTransition(.crossFade)
        .nwAnimation(.content, value: variant)
        .frame(maxWidth: AppLayout.emptyWorkspaceMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}

// MARK: Agent layout

/// An agent's layout with its right pane (an inspected subagent, else its review) docked beside
/// the whole layout, never inside the thread's pane: the dock rule measures the main column, so a
/// terminal split beside the thread neither halves the width it measures nor leaves the pane
/// covering the thread.
struct AgentLayoutView: View {
    var vm: ShepherdViewModel
    let tab: Tab

    var body: some View {
        let thread = tab.layout.leaves.lazy.compactMap { pane in
            primaryAgent(in: tab, pane: pane, agents: vm.state.agents).map { (agentID: $0.id, paneID: pane.id) }
        }.first
        let inspecting = thread.flatMap { vm.subagentInspector.runByAgent[$0.agentID] }
        let review = thread.flatMap { thread in vm.reviewSessions.values.first { $0.agentID == thread.agentID } }
        // The layout stays the first child whether or not a pane is open, so opening one never
        // remounts a pane's surface.
        RightPaneSplit(state: vm.subagentInspector, showPane: inspecting != nil || review != nil) {
            PaneTreeView(vm: vm, tab: tab, node: tab.layout)
        } pane: {
            if let thread {
                let agentID = thread.agentID
                let store = vm.threadStores.store(for: agentID)
                RightPaneSlot(showing: inspecting.map { .inspector(runID: $0) } ?? review.map { .review($0.id) }) {
                    if let inspecting {
                        SubagentInspector(store: store, runID: inspecting, active: vm.isVisibleTab(tab), close: { [vm] in
                            vm.subagentInspector.runByAgent.removeValue(forKey: agentID)
                        }, select: { [vm] in vm.subagentInspector.runByAgent[agentID] = $0.runID }, fork: { [vm] run in
                            do { try await vm.forkSubagent(agentID: agentID, run: run); return nil } catch { return String(describing: error) }
                        }, review: { [vm] in vm.openReview(agentID: agentID, path: $0) })
                        // The inspector keys its run itself, so a run switch nudges in from its side.
                        .nwTransition(.content)
                    } else if let review {
                        ReviewPaneHost(session: review, actions: vm.reviewActions(for: review, remote: false), store: store)
                            .id(review.id)
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
    let tab: Tab
    let node: PaneNode
    @State private var liveRatios: [PaneSplitPath: Double] = [:]

    private var containerSpace: String { "split-\(tab.id)" }

    var body: some View {
        GeometryReader { geo in
            let geometry = paneTreeGeometry(for: node, in: geo.size, liveRatios: liveRatios)
            let visible = vm.isVisibleTab(tab)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    PaneLeafView(vm: vm, tab: tab, model: leafModel(leaf.pane, visible: visible))
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
        paneSeparatorColor(split, focused: vm.focusedPaneID)
    }

    /// Everything a leaf draws, resolved here so the leaf itself reads nothing observable and
    /// re-renders only when one of these values changes.
    private func leafModel(_ pane: LeafPane, visible: Bool) -> PaneLeafModel {
        let agent = primaryAgent(in: tab, pane: pane, agents: vm.state.agents)
        return PaneLeafModel(
            pane: pane,
            isVisible: visible,
            // Hidden layouts stay mounted, so a pane only holds keyboard focus while its own
            // layout is the visible one; otherwise a background terminal would swallow typing.
            isFocused: visible && vm.focusedPaneID == pane.id,
            agentID: agent?.id,
            agentName: agent?.name ?? "",
            piSessionID: agent?.effectivePiSessionID,
            inspectingRunID: agent.flatMap { vm.subagentInspector.runByAgent[$0.id] }
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
                    inspectedRunID: inspecting,
                    review: { [vm] path in vm.selectAgent(agentID); vm.openReview(agentID: agentID, path: path) }
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
    var inspectedRunID: String? = nil
    var review: ((String) -> Void)? = nil

    var body: some View {
        // The placeholder cross-fades in when pi dies; connecting → live changes nothing here.
        ZStack {
            switch session.phase {
            case .connecting, .live:
                ThreadView(store: store, active: active, isFocused: isFocused, request: request, preview: preview, commandKey: commandKey,
                           agentName: agentName, workingDirectory: workingDirectory, inspectSubagent: inspectSubagent,
                           inspectedRunID: inspectedRunID, review: review)
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
        ZStack {
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
            case .failed(let reason):
                PanePlaceholder(text: "\(connection.config.name) unreachable · \(reason)")
                    .nwTransition(.content)
            case .disconnected:
                PanePlaceholder(text: "\(connection.config.name) disconnected")
                    .nwTransition(.content)
            }
        }
        .nwAnimation(.content, value: connection.phase.kind)
    }
}

/// A remote agent's layout with its right pane docked beside the whole layout, as
/// `AgentLayoutView` does locally. The host's inspector tab (a utility terminal) has none.
private struct RemoteAgentLayoutView: View {
    var vm: ShepherdViewModel
    var connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let tab: Tab

    var body: some View {
        let threadPaneID = tab.layout.leaves.first { primaryAgent(in: tab, pane: $0, agents: connection.state.agents) != nil }?.id
        let inspecting = threadPaneID == nil ? nil : vm.subagentInspector.remoteRuns[ref]
        // A review a host layout still carries as a leaf (older hosts) renders there instead.
        let review = threadPaneID == nil ? nil : vm.remoteReviews[ref].flatMap { $0.hostReviewPane ? nil : $0 }
        RightPaneSplit(state: vm.subagentInspector, showPane: inspecting != nil || review != nil) {
            RemotePaneTreeView(vm: vm, connection: connection, ref: ref, tab: tab, node: tab.layout)
        } pane: {
            if let threadPaneID {
                let store = vm.remoteThreadStores.store(for: ref)
                RightPaneSlot(showing: inspecting.map { .inspector(runID: $0) } ?? review.map { .review($0.id) }) {
                    if let inspecting {
                        SubagentInspector(store: store, runID: inspecting, active: true, close: { [vm, ref] in
                            vm.subagentInspector.remoteRuns.removeValue(forKey: ref)
                        }, select: { [vm, ref] in vm.subagentInspector.remoteRuns[ref] = $0.runID }, fork: nil,
                        review: { [vm, ref] in vm.openRemoteReview(ref, path: $0) })
                        // The inspector keys its run itself, so a run switch nudges in from its side.
                        .nwTransition(.content)
                    } else if let review {
                        ReviewPaneHost(session: review, actions: vm.reviewActions(for: review, remote: true), store: store)
                            .id(review.id)
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
    @State private var liveRatios: [PaneSplitPath: Double] = [:]

    private var containerSpace: String { "remote-split-\(tab.id)" }

    var body: some View {
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
                    ReviewPane(session: review, actions: vm.reviewActions(for: review, remote: true))
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
            inspectedRunID: inspecting,
            review: { path in vm.openRemoteReview(ref, path: path) },
            listModels: {
                let ids = (try? await vm.remoteHosts.listModels(hostID: ref.hostID).models) ?? []
                return ids.map { PiModelCatalog.Entry(id: $0) }
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

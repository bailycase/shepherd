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
                    PaneTreeView(vm: vm, tab: tab, node: tab.layout)
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
                }

                if let remote = vm.selectedRemoteAgent {
                    RemoteAgentPane(vm: vm, ref: remote)
                        .id(remote)
                }

                if visibleTabID == nil, vm.selectedRemoteAgent == nil {
                    EmptyWorkspace(vm: vm)
                }
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

/// No agent on screen: a space with no agents yet, or no spaces at all.
struct EmptyWorkspace: View {
    var vm: ShepherdViewModel
    @ObservedObject private var keys = KeybindingsStore.shared

    var body: some View {
        Group {
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
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
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
            let separatorSpan = span > 0 ? 1.0 : 0.0
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
            ZStack(alignment: .topLeading) {
                ForEach(geometry.leaves, id: \.pane.id) { leaf in
                    PaneLeafView(vm: vm, tab: tab, pane: leaf.pane)
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
        guard let focused = vm.focusedPaneID,
              case .split(_, _, let first, let second) = split else {
            return Color.nw.lineSubtle
        }
        let bordersFocused = first.contains(focused) || second.contains(focused)
        return bordersFocused ? Color.nw.running.opacity(0.34) : Color.nw.lineSubtle
    }
}

private struct PaneSeparatorView: View {
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
                    .frame(width: axis == .vertical ? 9 : nil, height: axis == .horizontal ? 9 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(dragGesture)
            }
            .offset(x: rect.minX, y: rect.minY)
            .zIndex(1)
    }

    private var dragGesture: some Gesture {
        // The root coordinate space does not move with the divider. Subtract
        // this split's origin to recover the same local position the nested
        // split view used, without corrupted moving-view translations.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                let span = axis == .vertical ? max(1, containerRect.width) : max(1, containerRect.height)
                let origin = axis == .vertical ? containerRect.minX : containerRect.minY
                let position = (axis == .vertical ? value.location.x : value.location.y) - origin
                liveRatio = min(0.85, max(0.15, position / span))
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

struct PaneLeafView: View {
    var vm: ShepherdViewModel
    let tab: Tab
    let pane: LeafPane

    var body: some View {
        // Hidden layouts stay mounted, so a pane only holds keyboard focus
        // while its own layout is the visible one — otherwise a background
        // agent's terminal would swallow typing.
        let visible = vm.isVisibleTab(tab)
        let focused = vm.focusedPaneID == pane.id && visible
        let agent = primaryAgent(in: tab, pane: pane, agents: vm.state.agents)

        Group {
            if pane.isReview == true {
                PanePlaceholder(text: "review unavailable")
            } else if let agent {
                // The thread is the agent's pane; the session binding still goes through the
                // store so a pi exit closes the pane. The right pane docks beside it: an
                // inspected subagent, else the agent's review.
                let store = vm.threadStores.store(for: agent.id)
                let inspecting = vm.subagentInspector.runByAgent[agent.id]
                let review = vm.reviewSessions.values.first { $0.agentID == agent.id }
                RightPaneSplit(state: vm.subagentInspector, showPane: inspecting != nil || review != nil) {
                    AgentThreadPane(
                        session: vm.sessions.session(for: pane, in: tab),
                        store: store,
                        active: visible,
                        isFocused: focused && inspecting == nil,
                        request: { try await vm.server.nativeThread(agentID: agent.id, request: $0) },
                        commandKey: ThreadCommandCenter.key(local: agent.id),
                        agentName: agent.name,
                        workingDirectory: pane.cwd,
                        inspectSubagent: { vm.toggleSubagentInspector(agentID: agent.id, runID: $0.runID) },
                        inspectedRunID: inspecting,
                        review: { path in vm.selectAgent(agent.id); vm.openReview(agentID: agent.id, path: path) }
                    )
                } pane: {
                    if let inspecting {
                        SubagentInspector(store: store, runID: inspecting, active: visible, close: {
                            vm.subagentInspector.runByAgent.removeValue(forKey: agent.id)
                        }, select: { vm.subagentInspector.runByAgent[agent.id] = $0.runID }, fork: { run in
                            do { try await vm.forkSubagent(agentID: agent.id, run: run); return nil } catch { return String(describing: error) }
                        }, review: { vm.openReview(agentID: agent.id, path: $0) })
                        .id(inspecting)
                    } else if let review {
                        ReviewPaneHost(session: review, actions: vm.reviewActions(for: review, remote: false), store: store)
                    }
                }
            } else {
                LiveTerminalPane(
                    session: vm.sessions.session(for: pane, in: tab),
                    isFocused: focused,
                    isRendering: visible
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { vm.focusedPaneID = pane.id })
    }
}

/// An agent's only surface. Observes the pane session for exit/failure so a dead pi shows
/// the same placeholder a shell pane would.
struct AgentThreadPane: View {
    @ObservedObject var session: TerminalSessionStore.PaneSession
    var store: NativeThreadStore
    let active: Bool
    let isFocused: Bool
    let request: NativeThreadStore.Request
    var commandKey: String?
    let agentName: String
    var workingDirectory: String?
    var inspectSubagent: ((ChildRun) -> Void)? = nil
    var inspectedRunID: String? = nil
    var review: ((String) -> Void)? = nil

    var body: some View {
        switch session.phase {
        case .connecting, .live:
            ThreadView(store: store, active: active, isFocused: isFocused, request: request, commandKey: commandKey,
                       agentName: agentName, workingDirectory: workingDirectory, inspectSubagent: inspectSubagent,
                       inspectedRunID: inspectedRunID, review: review)
        case .failed(let reason):
            PanePlaceholder(text: "session unavailable · \(reason)")
        case .exited(let code):
            PanePlaceholder(text: code.map { "session exited (\($0))" } ?? "session exited")
        }
    }
}

struct LiveTerminalPane: View {
    @ObservedObject var session: TerminalSessionStore.PaneSession
    let isFocused: Bool
    /// False for a mounted-but-hidden pane, which keeps its surface but must
    /// stop running a render loop.
    var isRendering: Bool = true

    var body: some View {
        switch session.phase {
        case .connecting, .live:
            // Keep one Ghostty view mounted across the connecting → live
            // transition. Replacing it here discards the just-replayed screen.
            ZStack(alignment: .topLeading) {
                AppTerminalView(model: session.terminal, isFocused: isFocused, isRendering: isRendering)
                if case .connecting = session.phase {
                    PanePlaceholder(text: "starting session…")
                        .allowsHitTesting(false)
                }
            }
        case .failed(let reason):
            PanePlaceholder(text: "session unavailable · \(reason)")
        case .exited(let code):
            PanePlaceholder(text: code.map { "session exited (\($0))" } ?? "session exited")
        }
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
    @ObservedObject var connection: RemoteHostStore.Connection
    let agentID: AgentID

    var body: some View {
        Group {
            switch connection.phase {
            case .connected:
                if let agent = connection.state.agents.first(where: { $0.id == agentID }),
                   let tab = connection.state.tabs.first(where: {
                       let ref = RemoteAgentRef(hostID: connection.id, agentID: agentID)
                       return $0.id == (vm.remoteInspectingAgent == ref ? vm.remoteInspectorTabs[ref] ?? agent.tabID : agent.tabID)
                   }) {
                    RemotePaneTreeView(
                        vm: vm,
                        connection: connection,
                        ref: RemoteAgentRef(hostID: connection.id, agentID: agentID),
                        tab: tab,
                        node: tab.layout
                    )
                    .id(tab.id)
                } else {
                    PanePlaceholder(text: "agent has no layout on \(connection.config.name)")
                }
            case .connecting:
                PanePlaceholder(text: "connecting to \(connection.config.name)…")
            case .failed(let reason):
                PanePlaceholder(text: "\(connection.config.name) unreachable · \(reason)")
            case .disconnected:
                PanePlaceholder(text: "\(connection.config.name) disconnected")
            }
        }
    }
}

private struct RemotePaneTreeView: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let tab: Tab
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let leaf):
            RemotePaneLeafView(vm: vm, connection: connection, ref: ref, tab: tab, leaf: leaf)
        case .split:
            RemotePaneSplitView(vm: vm, connection: connection, ref: ref, tab: tab, node: node)
        }
    }
}

private struct RemotePaneLeafView: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let tab: Tab
    let leaf: LeafPane

    var body: some View {
        Group {
            if let agent = primaryAgent(in: tab, pane: leaf, agents: connection.state.agents) {
                RemoteAgentThreadPane(vm: vm, ref: ref, agentName: agent.name, isFocused: vm.remoteFocusedPaneID == leaf.id)
            } else if leaf.isReview == true, let target = vm.selectedRemoteAgent {
                if let review = vm.remoteReviews[target], review.paneID == leaf.id {
                    ReviewPane(session: review, actions: vm.reviewActions(for: review, remote: true))
                } else {
                    PanePlaceholder(text: "loading host review…")
                        .task { vm.openRemoteHostReview(target, pane: leaf) }
                }
            } else if let sessionID = leaf.sessionID,
               let pane = vm.remoteHosts.paneSession(connection: connection, sessionID: sessionID) {
                RemoteTerminalPane(pane: pane, isFocused: vm.remoteFocusedPaneID == leaf.id)
                    .id(sessionID)
                    .onDisappear { vm.remoteHosts.closePane(connection: connection, sessionID: sessionID) }
            } else {
                PanePlaceholder(text: "starting remote pane…")
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { vm.remoteFocusedPaneID = leaf.id })
    }
}

private struct RemotePaneSplitView: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection
    let ref: RemoteAgentRef
    let tab: Tab
    let node: PaneNode
    @State private var liveRatio: Double?

    private var containerSpace: String { "remote-split-\(tab.id)" }

    var body: some View {
        if case .split(let axis, let ratio, let first, let second) = node {
            let shownRatio = liveRatio ?? ratio
            GeometryReader { geo in
                if axis == .vertical {
                    HStack(spacing: 0) {
                        child(first).frame(width: max(0, (geo.size.width - 1) * shownRatio))
                        separator(axis: axis, size: geo.size)
                        child(second).frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        child(first).frame(height: max(0, (geo.size.height - 1) * shownRatio))
                        separator(axis: axis, size: geo.size)
                        child(second).frame(maxHeight: .infinity)
                    }
                }
            }
            .coordinateSpace(.named(containerSpace))
        }
    }

    private func child(_ child: PaneNode) -> some View {
        RemotePaneTreeView(vm: vm, connection: connection, ref: ref, tab: tab, node: child)
    }

    private func separator(axis: SplitAxis, size: CGSize) -> some View {
        Color.nw.lineSubtle
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? 9 : nil, height: axis == .horizontal ? 9 : nil)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(containerSpace))
                            .onChanged { value in
                                let span = axis == .vertical ? max(1, size.width) : max(1, size.height)
                                let position = axis == .vertical ? value.location.x : value.location.y
                                liveRatio = min(0.85, max(0.15, position / span))
                            }
                            .onEnded { _ in
                                if let ratio = liveRatio {
                                    vm.commitRemoteSplitRatio(ref: ref, split: node, ratio: ratio)
                                }
                                liveRatio = nil
                            }
                    )
            }
    }
}

/// A remote agent's thread. Same view as a local agent's, with requests sent to the host.
private struct RemoteAgentThreadPane: View {
    var vm: ShepherdViewModel
    let ref: RemoteAgentRef
    let agentName: String
    let isFocused: Bool

    var body: some View {
        let store = vm.remoteThreadStores.store(for: ref)
        let inspecting = vm.subagentInspector.remoteRuns[ref]
        // A review a host layout still carries as a leaf (older hosts) renders there instead.
        let review = vm.remoteReviews[ref].flatMap { $0.hostReviewPane ? nil : $0 }
        RightPaneSplit(state: vm.subagentInspector, showPane: inspecting != nil || review != nil) {
            ThreadView(
                store: store,
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
        } pane: {
            if let inspecting {
                SubagentInspector(store: store, runID: inspecting, active: true, close: {
                    vm.subagentInspector.remoteRuns.removeValue(forKey: ref)
                }, select: { vm.subagentInspector.remoteRuns[ref] = $0.runID }, fork: nil,
                review: { vm.openRemoteReview(ref, path: $0) })
                .id(inspecting)
            } else if let review {
                ReviewPaneHost(session: review, actions: vm.reviewActions(for: review, remote: true), store: store)
            }
        }
    }
}

private struct RemoteTerminalPane: View {
    @ObservedObject var pane: RemotePaneSession
    let isFocused: Bool

    var body: some View {
        switch pane.phase {
        case .connecting, .live:
            ZStack(alignment: .topLeading) {
                AppTerminalView(model: pane.terminal, isFocused: isFocused, isRendering: true)
                if case .connecting = pane.phase {
                    PanePlaceholder(text: "attaching…").allowsHitTesting(false)
                }
            }
            .background(Color.nw.bgWindow)
        case .failed(let reason):
            PanePlaceholder(text: "remote session unavailable · \(reason)")
        case .exited(let code):
            PanePlaceholder(text: code.map { "remote session exited (\($0))" } ?? "remote session exited")
        }
    }
}

struct PanePlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.nwMono(10.5))
            .foregroundStyle(Color.nw.textTertiary)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

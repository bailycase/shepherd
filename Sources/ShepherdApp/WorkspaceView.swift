import SwiftUI
import AppKit
import ShepherdCore

struct WorkspaceView: View {
    var vm: ShepherdViewModel

    /// The frame is the app's one attention surface: neutral hairline
    /// normally, the status color when the focused agent is blocked.
    private var frameColor: Color {
        vm.selectedAgent?.status == .blocked ? Tokens.statusBlocked : Tokens.paneBorder
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Every mounted layout stays mounted; switching agents only
                // changes which one is visible. Unmounting would destroy the
                // Ghostty views and force a re-attach + full replay on every
                // switch, which is what made switching flash. Hidden panes
                // keep their surfaces, scrollback, and their process's real
                // grid. Space shell layouts join the mounted set on first
                // visit (see WorkspaceSelection).
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

                if mounted.isEmpty, vm.selectedRemoteAgent == nil {
                    EmptyWorkspaceHint(hasSpaces: !vm.state.spaces.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.workspaceBg)
            .border(frameColor, width: 1)
            .padding(.horizontal, Metrics.paneFrameInset)
            .padding(.bottom, Metrics.paneFrameInset)

            StatusLineView(vm: vm)
        }
        // A lazily mounted space shell must stay mounted once shown;
        // recording here catches every path that changes the active tab.
        .onChange(of: vm.activeTabID, initial: true) { vm.noteActiveTabVisited() }
        .background(Tokens.workspaceBg)
        // Window-level file/image drop routing for terminal panes; per-pane
        // SwiftUI .onDrop cannot coexist with permanently mounted hidden
        // layouts (see TerminalDropOverlay.swift).
        .background(AppTerminalDropOverlay())
    }
}

/// Quiet centered hint for an empty workspace — no cards, no buttons.
struct EmptyWorkspaceHint: View {
    let hasSpaces: Bool
    @ObservedObject private var keys = KeybindingsStore.shared

    var body: some View {
        let newAgent = keys.display(.newAgent)
        return Text(
            hasSpaces
                ? "\(newAgent) to create an agent"
                : "no spaces — + new space below, or \(newAgent) to create your first agent"
        )
        .font(Fonts.mono(11))
        .foregroundStyle(Tokens.textDim)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .coordinateSpace(name: containerSpace)
    }

    private func separatorColor(for split: PaneNode) -> Color {
        guard let focused = vm.focusedPaneID,
              case .split(_, _, let first, let second) = split else {
            return Tokens.paneBorder
        }
        let bordersFocused = first.contains(focused) || second.contains(focused)
        return bordersFocused ? Tokens.focusAccent.opacity(0.34) : Tokens.paneBorder
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
        let launching = pane.agentID.map { vm.launchingAgents.contains($0) } ?? false

        Group {
            if pane.isReview == true {
                if let session = vm.reviewSessions[pane.id] {
                    DiffReviewPane(session: session, isFocused: focused)
                        .environment(vm)
                } else {
                    PanePlaceholder(text: "review unavailable")
                }
            } else {
                ZStack {
                    LiveTerminalPane(
                        session: vm.sessions.session(for: pane, in: tab),
                        agentID: pane.agentID,
                        isFocused: focused,
                        isRendering: visible
                    )
                    // A just-created agent's terminal boots behind an opaque cover:
                    // login-shell echo and pi's first paint are noise, not content.
                    // Visual only — hit testing passes through, and the surface
                    // keeps keyboard focus, so typing lands in pi's prompt.
                    if launching {
                        AgentLaunchOverlay()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? nil
                        : .easeOut(duration: 0.12),
                    value: launching
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.terminalBg)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { vm.focusedPaneID = pane.id })
    }
}

// AgentLaunchOverlay (the ASCII crook boot screen) lives in
// AgentLaunchOverlay.swift.

struct LiveTerminalPane: View {
    @ObservedObject var session: TerminalSessionStore.PaneSession
    let agentID: AgentID?
    let isFocused: Bool
    @ObservedObject private var piUpdates = PiUpdateManager.shared
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
                if agentID != nil, piUpdates.isOutdated {
                    PiOutdatedOverlay()
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

/// The terminal of an agent on a remote host, streamed over that host's
/// connection. One pane, no splits: remote agents render their pi terminal
/// only — auxiliary panes stay a host-side concern.
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
                   let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) {
                    RemotePaneTreeView(
                        vm: vm,
                        connection: connection,
                        ref: RemoteAgentRef(hostID: connection.id, agentID: agentID),
                        tab: tab,
                        node: tab.layout
                    )
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
        .onDisappear {
            guard let agent = connection.state.agents.first(where: { $0.id == agentID }),
                  let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) else { return }
            vm.remoteHosts.closePanes(
                connection: connection,
                sessionIDs: tab.layout.leaves.compactMap(\.sessionID)
            )
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
            RemotePaneLeafView(vm: vm, connection: connection, leaf: leaf)
        case .split:
            RemotePaneSplitView(vm: vm, connection: connection, ref: ref, tab: tab, node: node)
        }
    }
}

private struct RemotePaneLeafView: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection
    let leaf: LeafPane

    var body: some View {
        Group {
            if let sessionID = leaf.sessionID,
               let pane = vm.remoteHosts.paneSession(connection: connection, sessionID: sessionID) {
                RemoteTerminalPane(pane: pane, isFocused: vm.remoteFocusedPaneID == leaf.id)
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
            .coordinateSpace(name: containerSpace)
        }
    }

    private func child(_ child: PaneNode) -> some View {
        RemotePaneTreeView(vm: vm, connection: connection, ref: ref, tab: tab, node: child)
    }

    private func separator(axis: SplitAxis, size: CGSize) -> some View {
        Tokens.paneBorder
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
            .background(Tokens.terminalBg)
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
            .font(Fonts.mono(10.5))
            .foregroundStyle(Tokens.textDim)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Status line

struct StatusLineView: View {
    var vm: ShepherdViewModel
    @ObservedObject private var keys = KeybindingsStore.shared
    @ObservedObject private var appearance = AppSettings.shared
    @State private var hoveringNewSpace = false

    var body: some View {
        HStack(spacing: 8) {
            // Leading queue segment — the only place the status line speaks,
            // and only about attention.
            if let queue = vm.waitingQueue {
                Text(queue.position.map { "\($0) of \(queue.total) waiting" } ?? "\(queue.total) waiting")
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.statusBlocked)
            }
            // The sidebar footer's affordances, relocated: new-space entry
            // point and the fleet dot counts.
            Text("+ new space")
                .font(Fonts.mono(11))
                .foregroundStyle(hoveringNewSpace ? Tokens.textSecondary : Tokens.textTertiary)
                .contentShape(Rectangle())
                .onHover { hoveringNewSpace = $0 }
                .onTapGesture { vm.addSpaceFromPanel() }
                .help("New Space (\(keys.display(.newSpace)))")
            HStack(spacing: 10) {
                ForEach(vm.statusCounts, id: \.status) { entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Tokens.statusColor(entry.status))
                            .frame(width: 6, height: 6)
                        Text("\(entry.count)")
                            .font(Fonts.mono(10))
                            .foregroundStyle(Tokens.textMetadata)
                    }
                    .help("\(entry.count) \(entry.status.rawValue)")
                }
            }
            Spacer()
            // Hints follow the user's actual bindings (DESIGN.md: never
            // advertise a chord that isn't wired).
            Text(
                [
                    "\(keys.display(.newAgent)) new agent",
                    "\(keys.display(.splitVertical)) split",
                    "\(keys.display(.focusNextPane)) pane",
                ].joined(separator: " · ")
            )
            .font(Fonts.mono(11))
            .foregroundStyle(Tokens.textHint)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.statusLineHeight)
        .background(Tokens.workspaceBg)
    }
}

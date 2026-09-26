import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The terminal panel's strip (TerminalSplit, TerminalStates boards): the tabs with + for a new
/// one, then Split right, Maximize or Restore, and Hide. Its top edge is the divider.
struct TerminalPanelBar: View {
    var vm: ShepherdViewModel
    let target: ShepherdViewModel.TerminalTarget
    let tabs: [TerminalPanelTab]
    let selected: TerminalPanelTab?
    let maximized: Bool
    /// The panel is on screen, so the selected tab's output is seen.
    let onScreen: Bool
    /// A remote tab names its host.
    let host: String?
    private var keys: KeybindingsStore { .shared }

    var body: some View {
        let panels = vm.terminalPanels
        let items = panels.items(target.key, tabs: tabs, selected: selected, onScreen: onScreen, host: host)
        NWTerminalTabBar(items, selection: selected?.id.rawValue, select: { id in
            if let tab = tabs.first(where: { $0.id.rawValue == id }) { vm.selectTerminalTab(tab, target: target) }
        }, close: { id in
            if let tab = tabs.first(where: { $0.id.rawValue == id }) { vm.closeTerminalTab(tab, target: target) }
        }, newTab: { vm.newTerminalTab(target) }, newTabHelp: "New terminal") {
            if selected != nil {
                Button { vm.splitTerminal(target) } label: { Image(systemName: "rectangle.split.2x1") }
                    .nwHelp("Split right", shortcut: keys.display(.splitVertical))
                    .accessibilityLabel("Split right")
            }
            Button { vm.toggleTerminalMaximized() } label: {
                Image(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .nwHelp(maximized ? "Restore" : "Maximize", shortcut: keys.display(.maximizeTerminal))
            .accessibilityLabel(maximized ? "Restore" : "Maximize")
            Button { vm.toggleTerminalPanel() } label: { Image(systemName: "xmark") }
                .nwHelp("Hide terminal", shortcut: keys.display(.toggleTerminal))
                .accessibilityLabel("Hide terminal")
        }
        .onChange(of: seenMark, initial: true) { _, mark in
            if !mark.sessions.isEmpty { panels.markSeen(target.key, sessions: mark.sessions) }
        }
    }

    /// The selected tab and how far its news has got, while it is on screen.
    private var seenMark: TerminalSeenMark {
        TerminalPanel.seenMark(selected: selected, onScreen: onScreen, activity: vm.terminalPanels.activity[target.key] ?? [:])
    }
}

/// The panel's top edge: drag it (it snaps at a third, half and two-thirds of the layout), or
/// double-click it to go back to 330pt. While it is dragged it draws as a 3pt lantern line
/// (TerminalStates › Divider). Adjustable with VoiceOver.
struct TerminalPanelDivider: View {
    var vm: ShepherdViewModel
    /// The layout's height, and the panel's height while it is dragged.
    let container: CGFloat
    @Binding var liveHeight: CGFloat?
    let coordinateSpace: String

    var body: some View {
        Color.clear
            .frame(height: AppLayout.resizeHandleWidth)
            .overlay {
                if liveHeight != nil {
                    Color.nw.lantern.frame(height: AppLayout.terminalDividerDragLine)
                }
            }
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
                .onChanged { value in
                    liveHeight = CGFloat(TerminalPanelHeight.resolve(
                        Double(container - value.location.y), container: Double(container),
                        minimum: Double(AppLayout.terminalPanelMinHeight), threadMinimum: Double(AppLayout.terminalThreadMinHeight),
                        tolerance: Double(AppLayout.terminalSnapTolerance)))
                }
                .onEnded { _ in
                    if let liveHeight { vm.terminalPanels.height = liveHeight }
                    liveHeight = nil
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { vm.terminalPanels.height = AppLayout.terminalPanelHeight })
            .accessibilityElement()
            .accessibilityLabel("Terminal height")
            .accessibilityValue("\(Int(vm.terminalPanels.height)) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 40 : -40
                vm.terminalPanels.height = CGFloat(TerminalPanelHeight.clamp(
                    Double(vm.terminalPanels.height + step), container: Double(container),
                    minimum: Double(AppLayout.terminalPanelMinHeight), threadMinimum: Double(AppLayout.terminalThreadMinHeight)))
            }
    }
}

/// The chrome a panel draws over its panes' places: the thread folded to one line while the
/// panel is maximized (TerminalStates), and each shown pane's header in a tab of several panes
/// (TerminalPane), naming what it runs. Its own view, so the activity it reads re-renders it
/// and not the layout around it.
struct TerminalPanelChrome: View {
    var vm: ShepherdViewModel
    let key: TerminalPanelKey
    let geometry: TerminalPanelGeometry
    let focused: PaneID?
    /// A remote layout's host, named in each pane's header.
    let host: String?
    /// The thread's title and state, for its folded line.
    let threadTitle: String
    let threadState: AgentState
    let focus: (PaneID) -> Void

    var body: some View {
        let rows = vm.terminalPanels.activity[key] ?? [:]
        ZStack(alignment: .topLeading) {
            if let fold = geometry.fold {
                NWTerminalFoldedThread(title: threadTitle, state: threadState,
                                       restoreShortcut: KeybindingsStore.shared.display(.maximizeTerminal)) { [vm] in
                    vm.toggleTerminalMaximized()
                }
                .frame(width: fold.width, height: fold.height)
                .offset(x: fold.minX, y: fold.minY)
            }
            ForEach(geometry.leaves.filter { $0.shown && $0.header != nil }, id: \.pane.id) { leaf in
                if let header = leaf.header {
                    NWTerminalPaneHeader(title: TerminalPanels.title(row: rows[leaf.pane.id], pane: leaf.pane), host: host,
                                         isFocused: leaf.pane.id == focused)
                        .contentShape(Rectangle())
                        .onTapGesture { focus(leaf.pane.id) }
                        .frame(width: header.width, height: header.height)
                        .offset(x: header.minX, y: header.minY)
                }
            }
        }
    }
}

/// A panel with no terminals yet.
struct TerminalPanelEmpty: View {
    var vm: ShepherdViewModel
    let target: ShepherdViewModel.TerminalTarget

    var body: some View {
        VStack(spacing: NW.Space.m) {
            Text("No terminals in this thread yet.")
                .font(.nw(.ui))
                .foregroundStyle(Color.nw.textSecondary)
            HStack(spacing: NW.Space.s) {
                Button("New Terminal") { vm.newTerminalTab(target) }
                    .buttonStyle(.nw(.secondary))
                NWKeycap(KeybindingsStore.shared.display(.splitVertical))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
    }
}

/// What an on-screen panel's terminals run: this Mac's server, or the agent's host, every two
/// seconds while the layout shows.
struct TerminalActivityPoll: ViewModifier {
    var vm: ShepherdViewModel
    let key: TerminalPanelKey
    let agent: AgentID?
    let remote: RemoteAgentRef?
    let active: Bool

    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active, let agent else { return }
            while !Task.isCancelled {
                if let remote {
                    if case .terminals(let rows)? = try? await vm.remoteHosts.agentQuery(remote, query: .terminals) {
                        vm.terminalPanels.setActivity(rows, for: key)
                    }
                } else {
                    vm.terminalPanels.setActivity(await vm.server.terminalActivity(agentID: agent), for: key)
                }
                try? await Task.sleep(for: AppLayout.terminalActivityInterval)
            }
        }
    }
}

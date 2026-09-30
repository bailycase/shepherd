import AppKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The terminal panel's strip (TerminalSplit, TerminalStates boards): the tabs with + for a new
/// one, then Maximize or Restore, and Hide. Its top edge is the divider.
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
        }, newTab: { vm.newTerminalTab(target) }, newTabHelp: "New terminal", menu: { id, anchor in
            panels.menu = TerminalMenuRequest(key: target.key, tab: id.map { PaneID(rawValue: $0) } ?? selected?.id, anchor: anchor)
        }) {
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

/// The chrome a panel draws over its terminals' places: the thread folded to one line while the
/// panel is maximized (TerminalStates). Its own view, so the thread's state it reads re-renders
/// it and not the layout around it.
struct TerminalPanelChrome: View {
    let geometry: TerminalPanelGeometry
    /// The thread's title and state, for its folded line.
    let threadTitle: String
    let threadState: AgentState
    let restore: () -> Void

    var body: some View {
        if let fold = geometry.fold {
            NWTerminalFoldedThread(title: threadTitle, state: threadState,
                                   restoreShortcut: KeybindingsStore.shared.display(.maximizeTerminal), restore: restore)
                .frame(width: fold.width, height: fold.height)
                .offset(x: fold.minX, y: fold.minY)
        }
    }
}

/// The menu on a tab (NewTerminalMenu), hanging under the strip from + or the tab that was
/// right-clicked: a new terminal in the thread's folder, and for the tab, Rename tab and Kill
/// process. A click anywhere else or esc closes it. Its own view, so opening it re-renders only
/// this layer.
struct TerminalMenuLayer: View {
    var vm: ShepherdViewModel
    let target: ShepherdViewModel.TerminalTarget
    let bar: CGRect
    let tabs: [TerminalPanelTab]
    private var keys: KeybindingsStore { .shared }

    var body: some View {
        let panels = vm.terminalPanels
        ZStack(alignment: .topLeading) {
            if let menu = panels.menu, menu.key == target.key {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { panels.menu = nil }
                    .accessibilityHidden(true)
                GeometryReader { geo in
                    content(menu)
                        .offset(x: min(max(NW.Space.s, bar.minX + menu.anchor), max(NW.Space.s, geo.size.width - NWTerminalMetrics.menuWidth - NW.Space.s)),
                                y: bar.maxY + NW.Space.xs)
                        .nwTransition(.overlay, edge: .top)
                }
                .background(EscapeCloses { panels.menu = nil })
            }
        }
        .nwAnimation(.overlay, value: panels.menu)
    }

    private func content(_ menu: TerminalMenuRequest) -> some View {
        let tab = menu.tab.flatMap { id in tabs.first { $0.id == id } }
        let control = vm.terminalControlAvailable(target)
        let close = { vm.terminalPanels.menu = nil }
        return NWTerminalMenu {
            NWChangesMenuRow("New terminal in the worktree", subtitle: vm.terminalPlace(target), systemImage: "terminal",
                             trailing: .chord(keys.display(.newTerminal)), tallHeight: NWTerminalMetrics.menuTallRowHeight) {
                close()
                vm.newTerminalTab(target)
            }
            if let tab {
                NWChangesMenuRow("Rename tab", systemImage: "pencil", enabled: control) {
                    close()
                    vm.renameTerminalTab(tab, target: target)
                }
                NWChangesMenuRow("Kill process", systemImage: "xmark", enabled: control && vm.terminalTabIsRunning(tab, target: target)) {
                    close()
                    vm.killTerminalProcess(in: tab, target: target)
                }
            }
        }
    }
}

/// Esc closes what shows while it does, whichever view has the keyboard (a terminal would
/// otherwise take the key).
private struct EscapeCloses: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> Monitor {
        let view = Monitor()
        view.close = close
        return view
    }

    func updateNSView(_ view: Monitor, context: Context) { view.close = close }

    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: NSView {
        var close: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, event.window === self?.window, let close = self?.close else { return event }
                close()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

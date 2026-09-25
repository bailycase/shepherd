import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension View {
    /// Hook (docs/ios/CONTRACTS.md): the thread's terminal panel on iPad (iPadTerminal board),
    /// under the thread and its composer, across the thread's width. `ThreadScreen` applies it
    /// to its content. On iPhone it adds nothing: the terminal opens full screen there
    /// (`TerminalRoute`).
    func threadTerminal(_ ref: AgentRef) -> some View {
        modifier(ThreadTerminalPanel(ref: ref))
    }
}

/// The thread with its panel under it. Maximized, the thread folds away (still mounted, so its
/// poll, draft and scroll stay) and the panel takes the column until it is restored.
private struct ThreadTerminalPanel: ViewModifier {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnHeight: CGFloat = 0
    @State private var visible = false

    func body(content: Content) -> some View {
        let terminals = MobileTerminals.shared
        let panel = terminals.panel(ref)
        let shows = sizeClass == .regular && panel.shown
        let maximized = shows && panel.maximized
        let height = TerminalPanelHeight.clamp(Double(terminals.panelHeight), container: Double(columnHeight),
                                               minimum: Double(NWTerminalMetrics.minimumPanelHeight),
                                               threadMinimum: Double(NWTerminalMetrics.minimumThreadHeight))
        VStack(spacing: 0) {
            content
                .frame(maxHeight: maximized ? 0 : .infinity)
                .clipped()
                .opacity(maximized ? 0 : 1)
                .allowsHitTesting(!maximized)
                .accessibilityHidden(maximized)
            if shows {
                TerminalPanelHost(ref: ref, columnHeight: columnHeight)
                    .frame(height: maximized ? nil : CGFloat(height))
                    .frame(maxHeight: maximized ? .infinity : nil)
                    .nwTransition(.pane, edge: .bottom)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if columnHeight != $0 { columnHeight = $0 } }
        .nwAnimation(.pane, value: shows)
        .nwAnimation(.pane, value: maximized)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        // The tabs' states and the header toggle's dot, while the thread is on screen (iPad).
        .task(id: ActivityKey(session: hosts.host(ref.host)?.session, watching: visible && scenePhase == .active && sizeClass == .regular)) {
            guard visible, sizeClass == .regular, let client = hosts.host(ref.host)?.connectedClient else { return }
            await watch(client)
        }
    }

    private struct ActivityKey: Equatable {
        var session: UUID?
        var watching: Bool
    }

    private func watch(_ client: RemoteHostClient) async {
        await MobileTerminals.shared.watchActivity(ref, client: client)
    }
}

/// Resolves the panel's values from the host and the store, and drops sessions the host no
/// longer lists.
private struct TerminalPanelHost: View {
    let ref: AgentRef
    let columnHeight: CGFloat
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let terminals = MobileTerminals.shared
        let model = TerminalModel.resolve(ref, hosts: hosts, terminals: terminals, onScreen: true)
        TerminalPanelView(model: model, columnHeight: columnHeight, problem: terminals.problems[ref])
            .onChange(of: liveSessions, initial: true) { _, live in
                if hosts.host(ref.host)?.phase.isConnected == true { terminals.prune(host: ref.host, live: live) }
            }
            .onChange(of: model.onScreenOutput, initial: true) {
                terminals.markSeen(ref, sessions: model.onScreenSessions)
            }
    }

    private var liveSessions: Set<SessionID> {
        Set(hosts.host(ref.host)?.state.tabs.flatMap { $0.layout.leaves.compactMap(\.sessionID) } ?? [])
    }
}

/// The panel (iPadTerminal board): the divider's grabber, the tab strip with + and the panel's
/// controls, the selected tab's panes, and the key row while a pane has the keyboard.
struct TerminalPanelView: View {
    let model: TerminalModel
    let columnHeight: CGFloat
    let problem: String?
    @Environment(MobileHosts.self) private var hosts
    @State private var closing: TerminalPanelTab?
    @State private var dragStart: CGFloat?

    var body: some View {
        let terminals = MobileTerminals.shared
        let selected = model.selected
        let focusedPane = selected.map { TerminalPanel.focusedPane(in: $0, focused: model.panel.focusedPane) }
        let focusedSession = selected?.panes.first { $0.id == focusedPane }?.sessionID
            .map { terminals.session(host: model.ref.host, id: $0) }
        VStack(spacing: 0) {
            NWTerminalTabBar(model.items, selection: selected?.id.rawValue, select: select,
                             close: model.canChangePanes && model.connected ? { id in closing = model.tab(for: id) } : nil,
                             newTab: model.canChangePanes && model.connected ? newTab : nil) {
                if let selected, model.canChangePanes, model.connected {
                    Button { split(selected, focused: focusedPane) } label: { Image(systemName: "rectangle.split.2x1") }
                        .accessibilityLabel("Split right")
                }
                Button {
                    terminals.update(model.ref) { $0.maximized.toggle() }
                } label: {
                    Image(systemName: model.panel.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel(model.panel.maximized ? "Restore" : "Maximize")
                Button {
                    terminals.update(model.ref) { $0.shown = false; $0.maximized = false }
                } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Hide terminal")
            }
            .overlay(alignment: .top) { grabber }
            if let problem {
                NWBanner(.failed, title: problem) {
                    Button("Dismiss") { terminals.problems[model.ref] = nil }.buttonStyle(.nw(.ghost, size: .s))
                }
                .padding(NW.Space.m)
            }
            ZStack {
                if let selected {
                    TerminalNodeView(ref: model.ref, node: selected.node,
                                     focusedPane: selected.panes.count > 1 ? focusedPane : nil)
                        .id(selected.id)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let focusedSession, focusedSession.focused {
                TerminalKeys(session: focusedSession)
            }
        }
        .background(Color.nw.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal")
        .confirmationDialog(closeConfirmation?.title ?? "", isPresented: closingShown, titleVisibility: .visible) {
            if let tab = closing {
                Button("Close Terminal", role: .destructive) { close(tab) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(closeConfirmation?.message ?? "")
        }
        .onChange(of: terminals.cannedClose, initial: true) { _, pane in
            if let pane, let tab = model.tab(for: pane.rawValue) { closing = tab }
        }
    }

    /// No tabs yet: the agent's layout has only its thread.
    private var empty: some View {
        VStack(spacing: NW.Space.m) {
            Text(model.connected ? "No terminals in this thread yet." : "\(model.hostName) is offline.")
                .font(.nw(.ui))
                .foregroundStyle(Color.nw.textSecondary)
            if model.canChangePanes, model.connected {
                Button("New Terminal", action: newTab)
                    .buttonStyle(.nw(.secondary))
                    .nwTouchTarget(height: NW.Height.controlM)
            } else if model.connected {
                Text("Update Shepherd on \(model.hostName) to open terminals here.")
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(NW.Space.xl)
    }

    /// Drag the panel's top edge: it snaps at a third, half and two-thirds of the column.
    private var grabber: some View {
        Capsule()
            .fill(Color.nw.lineStrong)
            .frame(width: MobileLayout.terminalGrabber.width, height: MobileLayout.terminalGrabber.height)
            .padding(.top, NW.Space.xs)
            .frame(width: NW.Height.touch * 2, height: NW.Height.touch / 2, alignment: .top)
            .contentShape(Rectangle())
            .opacity(model.panel.maximized ? 0 : 1)
            .allowsHitTesting(!model.panel.maximized)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let terminals = MobileTerminals.shared
                    let start = dragStart ?? terminals.panelHeight
                    if dragStart == nil { dragStart = start }
                    terminals.panelHeight = CGFloat(TerminalPanelHeight.resolve(
                        Double(start - value.translation.height), container: Double(columnHeight),
                        minimum: Double(NWTerminalMetrics.minimumPanelHeight),
                        threadMinimum: Double(NWTerminalMetrics.minimumThreadHeight),
                        tolerance: Double(NWTerminalMetrics.snapTolerance)))
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Terminal height")
            .accessibilityValue("\(Int(MobileTerminals.shared.panelHeight)) points")
            .accessibilityAdjustableAction { direction in
                let terminals = MobileTerminals.shared
                let step: CGFloat = direction == .increment ? 40 : -40
                terminals.panelHeight = CGFloat(TerminalPanelHeight.clamp(
                    Double(terminals.panelHeight + step), container: Double(columnHeight),
                    minimum: Double(NWTerminalMetrics.minimumPanelHeight),
                    threadMinimum: Double(NWTerminalMetrics.minimumThreadHeight)))
            }
    }

    private var closingShown: Binding<Bool> {
        Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })
    }

    private var closeConfirmation: TerminalCloseConfirmation? {
        closing.map { model.closeConfirmation($0) }
    }

    private func select(_ id: String) {
        guard let tab = model.tab(for: id) else { return }
        MobileTerminals.shared.choose(tab, in: model.ref)
    }

    private func newTab() {
        guard let layout = model.layout, let client = hosts.host(model.ref.host)?.connectedClient else { return }
        Task { await MobileTerminals.shared.newTab(model.ref, layout: layout, thread: model.thread, client: client) }
    }

    private func split(_ tab: TerminalPanelTab, focused: PaneID?) {
        guard let client = hosts.host(model.ref.host)?.connectedClient else { return }
        let anchor = TerminalPanel.splitAnchor(in: tab, focused: focused)
        Task { await MobileTerminals.shared.split(model.ref, pane: anchor, axis: .vertical, client: client) }
    }

    private func close(_ tab: TerminalPanelTab) {
        guard let client = hosts.host(model.ref.host)?.connectedClient else { return }
        let panes = TerminalPanel.panesToClose(tab, thread: model.thread)
        Task { await MobileTerminals.shared.close(model.ref, panes: panes, client: client) }
    }
}

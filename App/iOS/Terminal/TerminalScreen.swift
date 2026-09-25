import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// iPhone: a thread's terminal panes full screen, from the thread's options. The tab strip on
/// top (+ opens another beside the thread, as on iPad), the selected tab's panes, and the key row
/// while a pane has the keyboard.
struct TerminalScreen: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @State private var closing: TerminalPanelTab?
    @Environment(\.scenePhase) private var scenePhase

    private struct ActivityKey: Equatable {
        var session: UUID?
        var active: Bool
    }

    var body: some View {
        let terminals = MobileTerminals.shared
        let model = TerminalModel.resolve(ref, hosts: hosts, terminals: terminals, onScreen: true)
        let selected = model.selected
        let focusedPane = selected.map { TerminalPanel.focusedPane(in: $0, focused: model.panel.focusedPane) }
        let focusedSession = selected?.panes.first { $0.id == focusedPane }?.sessionID
            .map { terminals.session(host: ref.host, id: $0) }
        VStack(spacing: 0) {
            NWTerminalTabBar(model.items, selection: selected?.id.rawValue, select: { id in
                if let tab = model.tab(for: id) { terminals.choose(tab, in: ref) }
            }, close: model.canChangePanes && model.connected ? { id in closing = model.tab(for: id) } : nil,
               newTab: model.canChangePanes && model.connected ? { newTab(model) } : nil) {
                EmptyView()
            }
            if let problem = terminals.problems[ref] {
                NWBanner(.failed, title: problem) {
                    Button("Dismiss") { terminals.problems[ref] = nil }.buttonStyle(.nw(.ghost, size: .s))
                }
                .padding(NW.Space.m)
            }
            ZStack {
                if let selected {
                    TerminalNodeView(ref: ref, node: selected.node, focusedPane: selected.panes.count > 1 ? focusedPane : nil)
                        .id(selected.id)
                } else {
                    VStack(spacing: NW.Space.m) {
                        Text(model.connected ? "No terminals in this thread yet." : "\(model.hostName) is offline.")
                            .font(.nw(.ui))
                            .foregroundStyle(Color.nw.textSecondary)
                        if model.canChangePanes, model.connected {
                            Button("New Terminal") { newTab(model) }
                                .buttonStyle(.nw(.secondary))
                                .nwTouchTarget(height: NW.Height.controlM)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(MobileLayout.gutter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let focusedSession, focusedSession.focused {
                TerminalKeys(session: focusedSession)
            }
        }
        .background(Color.nw.bgWindow)
        .onChange(of: model.onScreenOutput, initial: true) { terminals.markSeen(ref, sessions: model.onScreenSessions) }
        // Sessions the host no longer lists let go of their screens, as the iPad panel's do.
        .onChange(of: liveSessions, initial: true) { _, live in
            if hosts.host(ref.host)?.phase.isConnected == true { terminals.prune(host: ref.host, live: live) }
        }
        .task(id: ActivityKey(session: hosts.host(ref.host)?.session, active: scenePhase == .active)) {
            guard scenePhase == .active, let client = hosts.host(ref.host)?.connectedClient else { return }
            await terminals.watchActivity(ref, client: client)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(closing.map { model.closeConfirmation($0).title } ?? "",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible) {
            if let tab = closing {
                Button("Close Terminal", role: .destructive) {
                    guard let client = hosts.host(ref.host)?.connectedClient else { return }
                    let panes = TerminalPanel.panesToClose(tab, thread: model.thread)
                    Task { await terminals.close(ref, panes: panes, client: client) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(closing.map { model.closeConfirmation($0).message } ?? "")
        }
    }

    private var liveSessions: Set<SessionID> {
        Set(hosts.host(ref.host)?.state.tabs.flatMap { $0.layout.leaves.compactMap(\.sessionID) } ?? [])
    }

    private func newTab(_ model: TerminalModel) {
        guard let layout = model.layout, let client = hosts.host(ref.host)?.connectedClient else { return }
        Task { await MobileTerminals.shared.newTab(ref, layout: layout, thread: model.thread, client: client) }
    }
}

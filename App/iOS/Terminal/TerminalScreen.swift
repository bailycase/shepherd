import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// iPhone: a thread's terminals full screen, from the thread's options. The tab strip on top (+
/// opens another under the thread, as on iPad), the selected tab's terminal, and the key row
/// while it has the keyboard. With no terminal yet the screen opens one.
struct TerminalScreen: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @State private var closing: TerminalPanelTab?
    /// The first terminal was asked for, once: closing it later never opens another by itself.
    @State private var askedForFirst = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private struct ActivityKey: Equatable {
        var session: UUID?
        var active: Bool
    }

    /// When to ask for a first terminal: once the host is connected and takes terminal requests.
    private struct FirstTerminalKey: Equatable {
        var connected: Bool
        var canChange: Bool
    }

    var body: some View {
        let terminals = MobileTerminals.shared
        let model = TerminalModel.resolve(ref, hosts: hosts, terminals: terminals, onScreen: true)
        let selected = model.selected
        let focusedSession = selected?.leaf.sessionID.map { terminals.session(host: ref.host, id: $0) }
        VStack(spacing: 0) {
            NWTerminalTabBar(model.items, selection: selected?.id.rawValue, select: { id in
                if let tab = model.tab(for: id) { terminals.choose(tab, in: ref) }
            }, close: model.canChangeTerminals && model.connected ? { id in closing = model.tab(for: id) } : nil,
               newTab: model.canChangeTerminals && model.connected ? { newTab(model) } : nil) {
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
                    TerminalPaneView(ref: ref, pane: selected.leaf)
                        .id(selected.id)
                } else {
                    VStack(spacing: NW.Space.m) {
                        if !model.connected {
                            Text("\(model.hostName) is offline.")
                                .font(.nw(.ui))
                                .foregroundStyle(Color.nw.textSecondary)
                        } else if !model.canChangeTerminals {
                            Text("Update Shepherd on \(model.hostName) to open terminals here.")
                                .font(.nw(.ui))
                                .foregroundStyle(Color.nw.textSecondary)
                        } else {
                            NWTerminalNotice("starting session…")
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
        .onChange(of: model.seenMark, initial: true) { _, mark in terminals.markSeen(ref, sessions: mark.sessions) }
        // Sessions the host no longer lists let go of their screens, as the iPad panel's do.
        .onChange(of: liveSessions, initial: true) { _, live in
            if hosts.host(ref.host)?.phase.isConnected == true { terminals.prune(host: ref.host, live: live) }
        }
        .task(id: ActivityKey(session: hosts.host(ref.host)?.session, active: scenePhase == .active)) {
            guard scenePhase == .active, let client = hosts.host(ref.host)?.connectedClient else { return }
            await terminals.watchActivity(ref, client: client)
        }
        .task(id: FirstTerminalKey(connected: model.connected, canChange: model.canChangeTerminals)) {
            guard model.connected, model.canChangeTerminals, model.tabs.isEmpty, !askedForFirst else { return }
            askedForFirst = true
            newTab(model)
        }
        // The screen closes with its last terminal, as the iPad's panel does.
        .onChange(of: model.tabs.count) { before, after in
            if TerminalPanel.closesWithLastTerminal(before: before, after: after) { dismiss() }
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
                    Task { await terminals.close(ref, terminal: tab.id, client: client) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(closing.map { model.closeConfirmation($0).message } ?? "")
        }
        .onChange(of: terminals.cannedClose, initial: true) { _, pane in
            if let pane, let tab = model.tab(for: pane.rawValue) { closing = tab }
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

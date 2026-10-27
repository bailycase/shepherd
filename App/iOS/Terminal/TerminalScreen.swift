import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A thread's terminals: full screen on iPhone, from the thread's menu; the side pane's Terminal
/// tab on regular width (`embedded`). The tab strip on top (+ opens another), the selected tab's
/// terminal, and the key row while it has the keyboard. With no terminal yet it opens one.
struct TerminalScreen: View {
    let ref: AgentRef
    /// In the side pane: no title or bars of its own, and it stays when its last terminal closes.
    var embedded = false
    @Environment(MobileHosts.self) private var hosts
    @State private var closing: TerminalPanelTab?
    @State private var renaming: TerminalPanelTab?
    @State private var terminalTitle = ""
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
        var hasLayout: Bool
    }

    var body: some View {
        let terminals = MobileTerminals.shared
        let model = TerminalModel.resolve(ref, hosts: hosts, terminals: terminals, onScreen: true)
        let selected = model.selected
        let focusedSession = selected?.leaf.sessionID.map { terminals.session(host: ref.host, id: $0) }
        VStack(spacing: 0) {
            SHTerminalTabBar(model.items, selection: selected?.id.rawValue, select: { id in
                if let tab = model.tab(for: id) { terminals.choose(tab, in: ref) }
            }, close: model.canChangeTerminals && model.connected ? { id in closing = model.tab(for: id) } : nil,
               newTab: model.canChangeTerminals && model.connected ? { newTab(model) } : nil) {
                if let selected, model.connected,
                   hosts.host(ref.host)?.supports(RemoteProtocol.terminalControlCapability) == true {
                    Menu {
                        Button("Rename Tab…") {
                            terminalTitle = selected.leaf.title ?? ""
                            renaming = selected
                        }
                        Button("Kill Process", role: .destructive) {
                            terminalAction(.killTerminalProcess(paneID: selected.id))
                        }
                    } label: {
                        Label("Terminal actions", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.sh(.ghost))
                    .accessibilityLabel("Actions for selected terminal")
                }
            }
            if let problem = terminals.problems[ref] {
                SHBanner(.failed, title: problem) {
                    if model.tabs.isEmpty {
                        Button("Retry") { newTab(model) }.buttonStyle(.sh(.ghost, size: .s))
                            .disabled(!model.connected || !model.canChangeTerminals)
                    }
                    Button("Dismiss") { terminals.problems[ref] = nil }.buttonStyle(.sh(.ghost, size: .s))
                }
                .padding(SH.Space.m)
            }
            ZStack {
                if let selected {
                    TerminalPaneView(ref: ref, pane: selected.leaf)
                        .id(selected.id)
                } else {
                    VStack(spacing: SH.Space.m) {
                        if !model.connected {
                            Text("\(model.hostName) is offline.")
                                .font(.sh(.ui))
                                .foregroundStyle(Color.sh.textSecondary)
                        } else if !model.canChangeTerminals {
                            Text("Update Shepherd on \(model.hostName) to open terminals here.")
                                .font(.sh(.ui))
                                .foregroundStyle(Color.sh.textSecondary)
                        } else if embedded, askedForFirst, model.tabs.isEmpty {
                            Text("No terminals. + opens one.")
                                .font(.sh(.ui))
                                .foregroundStyle(Color.sh.textSecondary)
                        } else {
                            SHTerminalNotice("starting session…")
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
        .background(Color.sh.bgWindow)
        .onChange(of: model.seenMark, initial: true) { _, mark in terminals.markSeen(ref, sessions: mark.sessions) }
        // Sessions the host no longer lists let go of their screens, as the iPad panel's do.
        .onChange(of: liveSessions, initial: true) { _, live in
            if hosts.host(ref.host)?.phase.isConnected == true { terminals.prune(host: ref.host, live: live) }
        }
        .task(id: ActivityKey(session: hosts.host(ref.host)?.session, active: scenePhase == .active)) {
            guard scenePhase == .active, let client = hosts.host(ref.host)?.connectedClient else { return }
            await terminals.watchActivity(ref, client: client)
        }
        .task(id: FirstTerminalKey(connected: model.connected, canChange: model.canChangeTerminals, hasLayout: model.layout != nil)) {
            guard model.connected, model.canChangeTerminals, model.layout != nil, model.tabs.isEmpty, !askedForFirst else { return }
            askedForFirst = true
            newTab(model)
        }
        // The screen closes with its last terminal.
        .onChange(of: model.tabs.count) { before, after in
            if !embedded, TerminalPanel.closesWithLastTerminal(before: before, after: after) { dismiss() }
        }
        .modifier(PushedTerminalChrome(active: !embedded))
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
        .alert("Rename terminal", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Tab name", text: $terminalTitle)
            Button("Rename") {
                guard let tab = renaming else { return }
                let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                terminalAction(.renameTerminal(paneID: tab.id, title: title.isEmpty ? nil : title))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave blank to use the running command's name.")
        }
        .onChange(of: terminals.cannedClose, initial: true) { _, pane in
            if let pane, let tab = model.tab(for: pane.rawValue) { closing = tab }
        }
    }

    private func terminalAction(_ action: RemoteAgentAction) {
        guard let host = hosts.host(ref.host), host.supports(RemoteProtocol.terminalControlCapability),
              let client = host.connectedClient else { return }
        Task {
            do {
                try await client.agentAction(agentID: ref.agent, action: action)
            } catch {
                MobileTerminals.shared.problems[ref] = MobileTerminals.message(error, doing: "change the terminal")
            }
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

/// The full-screen terminal's bar: its title, no tab bar.
private struct PushedTerminalChrome: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .toolbar(.hidden, for: .tabBar)
                .navigationTitle("Terminal")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

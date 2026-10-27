import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What a thread's terminal shows, resolved once per change from its host and the panel state:
/// the views below read only these values.
struct TerminalModel: Equatable {
    let ref: AgentRef
    let hostName: String
    /// A live connection, and one that takes terminal requests (`pane.control.v1`).
    let connected: Bool
    let canChangeTerminals: Bool
    let layout: PaneNode?
    let thread: PaneID?
    let tabs: [TerminalPanelTab]
    let selected: TerminalPanelTab?
    let panel: MobileTerminals.Panel
    /// The tab strip's items.
    let items: [SHTerminalTab]

    /// The tab on screen, its session and how far its news has got: it is marked seen whenever
    /// that changes.
    let seenMark: TerminalSeenMark

    /// A tab not on screen printed, or one exited: the header toggle's dot.
    var hasNews: Bool {
        items.contains { item in
            if case .exited = item.activity { return true }
            return item.activity == .unseen
        }
    }

    /// `onScreen`: the selected tab is showing (the iPad panel is open, or the iPhone's screen is
    /// up), so its output is seen.
    @MainActor static func resolve(_ ref: AgentRef, hosts: MobileHosts, terminals: MobileTerminals, onScreen: Bool) -> TerminalModel {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let tab = agent.flatMap { agent in host?.state.tabs.first { $0.id == agent.tabID } }
        let layout = tab?.layout
        let thread = agent?.paneID
        let tabs = layout.map { TerminalPanel.tabs(in: $0, thread: thread) } ?? []
        let panel = terminals.panel(ref)
        let selected = TerminalPanel.selected(tabs, chosen: panel.chosenTab)
        let activity = terminals.activity[ref] ?? [:]
        let items = tabs.map { tab in
            let session = tab.leaf.sessionID.flatMap { terminals.existingSession(host: ref.host, id: $0) }
            let state: SHTerminalTab.Activity
            if case .exited(let code)? = session?.phase { state = .exited(failed: (code ?? 0) != 0) }
            else if activity[tab.id]?.isRunning == true { state = .running }
            else if tab.id != selected?.id || !onScreen,
                    tab.leaf.sessionID.map({ terminals.hasUnseen(ref, session: $0) }) == true {
                state = .unseen
            } else { state = .idle }
            return SHTerminalTab(id: tab.id.rawValue, title: Self.title(activity: activity[tab.id], session: session, pane: tab.leaf),
                                 host: host?.name, activity: state)
        }
        return TerminalModel(ref: ref, hostName: host?.name ?? "the host", connected: host?.connectedClient != nil,
                             canChangeTerminals: host?.supports(RemoteProtocol.paneControlCapability) == true,
                             layout: layout, thread: thread, tabs: tabs, selected: selected, panel: panel, items: items,
                             seenMark: TerminalPanel.seenMark(selected: selected, onScreen: onScreen, activity: activity))
    }

    /// The running command ("make dev"), else the program at the prompt ("zsh"), else the
    /// shell's own title, else the folder it started in.
    @MainActor private static func title(activity: RemoteTerminalActivity?, session: MobileTerminalSession?, pane: LeafPane?) -> String {
        if let title = pane?.title, !title.isEmpty { return title }
        if let command = activity?.command, !command.isEmpty { return String(command.prefix(40)) }
        if let process = activity?.process, !process.isEmpty { return process }
        if let title = session?.title { return String(title.prefix(40)) }
        if let cwd = pane?.cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty, name != "/" { return name }
        }
        return "Terminal"
    }

    func tab(for id: String) -> TerminalPanelTab? { tabs.first { $0.id.rawValue == id } }

    /// What closing `tab` asks: which tab (its place when another has its title) and the shell
    /// that stops.
    func closeConfirmation(_ tab: TerminalPanelTab) -> TerminalCloseConfirmation {
        TerminalCloseConfirmation(tab, in: tabs, titles: items.map(\.title), host: hostName)
    }
}

/// One terminal: the host session's screen, attached while it is on screen, the app is active
/// and its host is connected. A terminal with no session yet, or one that failed or exited, says
/// so in the terminal's quiet notice.
struct TerminalPaneView: View {
    let ref: AgentRef
    let pane: LeafPane
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    /// This view, as the one window a session's screen may be in (`MobileTerminalSession.viewer`).
    @State private var viewer = UUID()
    @State private var startError: String?
    @State private var retryStart = 0

    private struct HoldKey: Equatable {
        var connection: UUID?
        var active: Bool
    }

    private struct DemandKey: Equatable {
        var retry: Int
        var paneID: PaneID
        var connection: UUID?
        var active: Bool
    }

    var body: some View {
        let terminals = MobileTerminals.shared
        let host = hosts.host(ref.host)
        Group {
            if pane.isReview == true {
                SHTerminalNotice("review open on \(host?.name ?? "the host")")
            } else if let id = pane.sessionID {
                let session = terminals.session(host: ref.host, id: id)
                let shown = session.viewer == viewer
                let key = HoldKey(connection: host?.connectedClient == nil ? nil : host?.session,
                                  active: visible && shown && scenePhase == .active)
                ZStack(alignment: .topLeading) {
                    // SwiftTerm's view is in one window at a time: another iPad window showing
                    // this thread says so instead of taking the screen from it.
                    if shown {
                        TerminalSurface(session: session)
                            .padding(SHTerminalMetrics.contentPadding)
                            .accessibilityLabel("Terminal on \(host?.name ?? "the host")")
                    } else if session.viewer != nil {
                        SHTerminalNotice("open in another window")
                    }
                    if shown, let notice = Self.notice(session.phase, canned: session.isCanned, connected: key.connection != nil,
                                                       held: key.active) {
                        SHTerminalNotice(notice)
                            .background(Color.sh.bgWindow.opacity(session.phase == .attaching ? 0 : 0.9))
                            .allowsHitTesting(false)
                            .shTransition(.content)
                    }
                }
                .shAnimation(.content, value: session.phase)
                .task(id: key) {
                    guard key.active, key.connection != nil, let client = host?.connectedClient else { return }
                    await session.hold(client)
                }
                .onAppear { session.claim(viewer) }
                .onDisappear { session.letGo(viewer) }
                // The window that had it let go: this one takes it if it is on screen.
                .onChange(of: session.viewer) { if session.viewer == nil, visible { session.claim(viewer) } }
                // One view per host session. The host gives a terminal a new session when it relaunches
                // (every terminal respawns its shell): the new one must claim the screen, make its own
                // surface and report its grid, or it never attaches and the old screen stays up.
                .id(id)
            } else if let startError {
                VStack(spacing: SH.Space.m) {
                    SHTerminalNotice(startError)
                    Button("Retry") { retryStart += 1 }
                        .buttonStyle(.sh(.secondary))
                        .disabled(host?.connectedClient == nil)
                }
            } else {
                SHTerminalNotice(host?.connectedClient == nil ? "host offline · reconnect to start" : "starting session…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sh.bgWindow)
        .contentShape(Rectangle())
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: DemandKey(retry: retryStart, paneID: pane.id, connection: host?.connectedClient == nil ? nil : host?.session,
                            active: visible && scenePhase == .active && host?.supports(RemoteProtocol.terminalStartCapability) == true)) {
            guard visible, scenePhase == .active, pane.isReview != true, pane.agentID == nil,
                  host?.supports(RemoteProtocol.terminalStartCapability) == true,
                  let client = host?.connectedClient else { return }
            // A non-nil binding can belong to the previous host process; demand is idempotent.
            startError = nil
            do {
                try await client.agentAction(agentID: ref.agent, action: .startTerminal(paneID: pane.id))
            } catch {
                guard !Task.isCancelled else { return }
                startError = MobileTerminals.message(error, doing: "start the terminal")
            }
        }
    }

    /// `held`: the terminal is attached while it shows, so a refused attach is being retried.
    private static func notice(_ phase: RemoteTerminalLink.Phase, canned: Bool, connected: Bool, held: Bool) -> String? {
        if canned { return nil }
        switch phase {
        case .detached: return connected ? "attaching…" : "host offline · reattaches when it is back"
        case .attaching: return "attaching…"
        case .live: return nil
        case .exited(let code): return code.map { "session exited (\($0))" } ?? "session exited"
        case .failed(let reason): return "session unavailable · \(reason)" + (held ? " · retrying" : "")
        }
    }
}

/// The key row under the terminal while it has the keyboard.
struct TerminalKeys: View {
    let session: MobileTerminalSession

    var body: some View {
        let keys = TerminalKey.allCases.map { key in
            SHTerminalKeycap(id: key.rawValue, label: key.label, spokenLabel: key.spokenLabel,
                             isLatched: (key == .control && session.control) || (key == .option && session.option))
        }
        SHTerminalKeyRow(keys) { id in
            if let key = TerminalKey(rawValue: id) { session.press(key) }
        }
    }
}

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
    /// A live connection, and one that takes pane requests (`pane.control.v1`).
    let connected: Bool
    let canChangePanes: Bool
    let layout: PaneNode?
    let thread: PaneID?
    let tabs: [TerminalPanelTab]
    let selected: TerminalPanelTab?
    let panel: MobileTerminals.Panel
    /// The tab strip's items.
    let items: [NWTerminalTab]

    /// The sessions on screen, and how far their output has got: they are marked seen as it moves.
    let onScreenSessions: [SessionID]
    let onScreenOutput: [UInt64]

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
        let selected = TerminalPanel.selected(tabs, chosen: panel.chosenTab, remembering: panel.chosenPanes, focused: panel.focusedPane)
        let activity = terminals.activity[ref] ?? [:]
        let items = tabs.map { tab in
            let first = tab.panes.first
            let session = first?.sessionID.flatMap { terminals.existingSession(host: ref.host, id: $0) }
            let rows = tab.panes.compactMap { activity[$0.id] }
            let state: NWTerminalTab.Activity
            if case .exited(let code)? = session?.phase { state = .exited(failed: (code ?? 0) != 0) }
            else if rows.contains(where: \.isRunning) { state = .running }
            else if tab.id != selected?.id || !onScreen,
                    tab.panes.contains(where: { pane in pane.sessionID.map { terminals.hasUnseen(ref, session: $0) } ?? false }) {
                state = .unseen
            } else { state = .idle }
            return NWTerminalTab(id: tab.id.rawValue, title: Self.title(activity: first.flatMap { activity[$0.id] }, session: session, pane: first),
                                 host: host?.name, activity: state, panes: tab.panes.count)
        }
        let seenSessions = onScreen ? selected?.panes.compactMap(\.sessionID) ?? [] : []
        return TerminalModel(ref: ref, hostName: host?.name ?? "the host", connected: host?.connectedClient != nil,
                             canChangePanes: host?.supports(RemoteProtocol.paneControlCapability) == true,
                             layout: layout, thread: thread, tabs: tabs, selected: selected, panel: panel, items: items,
                             onScreenSessions: seenSessions,
                             onScreenOutput: seenSessions.map { id in activity.values.first { $0.sessionID == id }?.outputSequence ?? 0 })
    }

    /// The running command ("make dev"), else the program at the prompt ("zsh"), else the
    /// shell's own title, else the folder it started in.
    @MainActor private static func title(activity: RemoteTerminalActivity?, session: MobileTerminalSession?, pane: LeafPane?) -> String {
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
}

/// One tab's panes with the host's splits: 1pt dividers, each side its share.
struct TerminalNodeView: View {
    let ref: AgentRef
    let node: PaneNode
    /// Outlined when the tab splits into more than one pane.
    let focusedPane: PaneID?

    var body: some View {
        switch node {
        case .leaf(let pane):
            TerminalPaneView(ref: ref, pane: pane, focused: focusedPane == pane.id)
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { geometry in
                let span = axis == .vertical ? geometry.size.width : geometry.size.height
                let firstSpan = max(0, (span - 1) * ratio)
                if axis == .vertical {
                    HStack(spacing: 0) {
                        TerminalNodeView(ref: ref, node: first, focusedPane: focusedPane)
                            .frame(width: firstSpan)
                        NWHairline(.vertical)
                        TerminalNodeView(ref: ref, node: second, focusedPane: focusedPane)
                    }
                } else {
                    VStack(spacing: 0) {
                        TerminalNodeView(ref: ref, node: first, focusedPane: focusedPane)
                            .frame(height: firstSpan)
                        NWHairline()
                        TerminalNodeView(ref: ref, node: second, focusedPane: focusedPane)
                    }
                }
            }
        }
    }
}

/// One terminal pane: the host session's screen, attached while it is on screen, the app is
/// active and its host is connected. A pane with no session yet, or one that failed or exited,
/// says so in the terminal's quiet notice.
struct TerminalPaneView: View {
    let ref: AgentRef
    let pane: LeafPane
    let focused: Bool
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    private struct HoldKey: Equatable {
        var connection: UUID?
        var active: Bool
    }

    var body: some View {
        let terminals = MobileTerminals.shared
        let host = hosts.host(ref.host)
        Group {
            if pane.isReview == true {
                NWTerminalNotice("review open on \(host?.name ?? "the host")")
            } else if let id = pane.sessionID {
                let session = terminals.session(host: ref.host, id: id)
                let key = HoldKey(connection: host?.connectedClient == nil ? nil : host?.session,
                                  active: visible && scenePhase == .active)
                ZStack(alignment: .topLeading) {
                    TerminalSurface(session: session)
                        .padding(NWTerminalMetrics.contentPadding)
                        .accessibilityLabel("Terminal on \(host?.name ?? "the host")")
                    if let notice = Self.notice(session.phase, canned: session.isCanned, connected: key.connection != nil) {
                        NWTerminalNotice(notice)
                            .background(Color.nw.bgWindow.opacity(session.phase == .attaching ? 0 : 0.9))
                            .allowsHitTesting(false)
                            .nwTransition(.content)
                    }
                }
                .nwAnimation(.content, value: session.phase)
                .task(id: key) {
                    guard key.active, key.connection != nil, let client = host?.connectedClient else { return }
                    await session.hold(client)
                }
            } else {
                NWTerminalNotice("starting session…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .overlay {
            if focused { Rectangle().strokeBorder(Color.nw.focusDivider, lineWidth: 1).allowsHitTesting(false) }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            terminals.update(ref) { $0.focusedPane = pane.id }
        })
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private static func notice(_ phase: RemoteTerminalLink.Phase, canned: Bool, connected: Bool) -> String? {
        if canned { return nil }
        switch phase {
        case .detached: return connected ? "attaching…" : "host offline · reattaches when it is back"
        case .attaching: return "attaching…"
        case .live: return nil
        case .exited(let code): return code.map { "session exited (\($0))" } ?? "session exited"
        case .failed(let reason): return "session unavailable · \(reason)"
        }
    }
}

/// The key row under the terminal while one of its panes has the keyboard.
struct TerminalKeys: View {
    let session: MobileTerminalSession

    var body: some View {
        let keys = TerminalKey.allCases.map { key in
            NWTerminalKeycap(id: key.rawValue, label: key.label, spokenLabel: key.spokenLabel,
                             isLatched: (key == .control && session.control) || (key == .option && session.option))
        }
        NWTerminalKeyRow(keys) { id in
            if let key = TerminalKey(rawValue: id) { session.press(key) }
        }
    }
}

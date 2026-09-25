import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Which layout a terminal panel belongs to: a local agent's, or a remote agent's on its host.
struct TerminalPanelKey: Hashable {
    var host: UUID?
    var tab: TabID
}

/// Each agent layout's terminal panel (TerminalSplit, TerminalStates boards): shown or hidden,
/// the tab on screen, maximized, and what its terminals run. The panes themselves stay the
/// layout's (`PaneNode`): the panel is how the Mac shows them, under the thread. Device-local
/// view state; the height persists app-wide (`shepherd.terminalPanelHeight`).
@MainActor
@Observable
final class TerminalPanels {
    struct Panel: Equatable {
        var shown = false
        /// The tab picked last, and its panes, so it stays picked when its first pane closes.
        var chosenTab: PaneID?
        var chosenPanes: [PaneID] = []
        var maximized = false
    }

    static let heightKey = "shepherd.terminalPanelHeight"

    private(set) var panels: [TerminalPanelKey: Panel] = [:]
    /// The panel's height; the thread keeps the rest.
    var height: CGFloat {
        didSet { if height != oldValue { defaults.set(Double(height), forKey: Self.heightKey) } }
    }
    /// What each layout's terminals run (`SessionServer.terminalActivity`, or a host's
    /// `RemoteAgentQuery.terminals`), by pane.
    private(set) var activity: [TerminalPanelKey: [PaneID: RemoteTerminalActivity]] = [:]
    /// Each session's news (`RemoteTerminalActivity.news`) when it was last on screen.
    private(set) var seen: [SessionID: UInt64] = [:]

    /// The panes each layout had when last reconciled: a pane that appears opens the panel on it.
    @ObservationIgnored private var known: [TerminalPanelKey: Set<PaneID>] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.heightKey)
        height = saved >= Double(AppLayout.terminalPanelMinHeight) ? CGFloat(saved) : AppLayout.terminalPanelHeight
    }

    func panel(_ key: TerminalPanelKey) -> Panel { panels[key] ?? Panel() }

    func update(_ key: TerminalPanelKey, _ change: (inout Panel) -> Void) {
        var panel = panels[key] ?? Panel()
        change(&panel)
        if panels[key] != panel { panels[key] = panel }
    }

    func choose(_ tab: TerminalPanelTab, in key: TerminalPanelKey) {
        update(key) {
            $0.chosenTab = tab.id
            $0.chosenPanes = tab.panes.map(\.id)
        }
    }

    /// The tab on screen in `layout`.
    func selectedTab(_ key: TerminalPanelKey, layout: PaneNode, thread: PaneID?, focused: PaneID?) -> TerminalPanelTab? {
        let panel = panel(key)
        return TerminalPanel.selected(TerminalPanel.tabs(in: layout, thread: thread), chosen: panel.chosenTab,
                                      remembering: panel.chosenPanes, focused: focused)
    }

    /// Follows the layout: the first time a layout is seen, its panel shows if it has terminals
    /// (as the panes always showed before the panel); after that, a terminal that appears (⌘D,
    /// an agent's `pane_open`, another device's +) opens the panel on its tab, and the panel
    /// closes with its last terminal. Returns the new pane to focus, if one appeared.
    @discardableResult
    func reconcile(_ key: TerminalPanelKey, layout: PaneNode, thread: PaneID?) -> PaneID? {
        let tabs = TerminalPanel.tabs(in: layout, thread: thread)
        let panes = Set(tabs.flatMap { $0.panes.map(\.id) })
        defer { known[key] = panes }
        guard let before = known[key] else {
            if !tabs.isEmpty, panels[key] == nil { update(key) { $0.shown = true } }
            return nil
        }
        if TerminalPanel.closesWithLastTerminal(before: before.count, after: panes.count) {
            update(key) {
                $0.shown = false
                $0.maximized = false
            }
            return nil
        }
        guard let added = tabs.flatMap(\.panes).map(\.id).last(where: { !before.contains($0) }),
              let tab = tabs.first(where: { $0.contains(added) }) else { return nil }
        update(key) {
            $0.shown = true
            $0.chosenTab = tab.id
            $0.chosenPanes = tab.panes.map(\.id)
        }
        return added
    }

    func forget(_ key: TerminalPanelKey) {
        panels[key] = nil
        known[key] = nil
        activity[key] = nil
    }

    // MARK: Activity

    func setActivity(_ rows: [RemoteTerminalActivity], for key: TerminalPanelKey) {
        let byPane = Dictionary(rows.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        if activity[key] != byPane { activity[key] = byPane }
        // Output from before the first look is not news.
        for row in rows where seen[row.sessionID] == nil { seen[row.sessionID] = row.news }
    }

    /// The sessions on screen: everything they printed is seen.
    func markSeen(_ key: TerminalPanelKey, sessions: [SessionID]) {
        for id in sessions {
            guard let sequence = activity[key]?.values.first(where: { $0.sessionID == id })?.news,
                  seen[id] != sequence else { continue }
            seen[id] = sequence
        }
    }

    func hasUnseen(_ key: TerminalPanelKey, session id: SessionID) -> Bool {
        guard let row = activity[key]?.values.first(where: { $0.sessionID == id }), let seen = seen[id] else { return false }
        return row.news > seen
    }

    /// The tab strip's items for a layout: the running command or the program at the prompt, a
    /// spinner while a command runs, and a dot for output printed while the tab was off screen.
    func items(_ key: TerminalPanelKey, tabs: [TerminalPanelTab], selected: TerminalPanelTab?, onScreen: Bool,
               host: String?) -> [NWTerminalTab] {
        let rows = activity[key] ?? [:]
        return tabs.map { tab in
            let first = tab.panes.first
            let row = first.flatMap { rows[$0.id] }
            let state: NWTerminalTab.Activity
            if tab.panes.contains(where: { rows[$0.id]?.isRunning == true }) {
                state = .running
            } else if tab.id != selected?.id || !onScreen,
                      tab.panes.contains(where: { pane in pane.sessionID.map { hasUnseen(key, session: $0) } ?? false }) {
                state = .unseen
            } else {
                state = .idle
            }
            return NWTerminalTab(id: tab.id.rawValue, title: Self.title(row: row, pane: first), host: host,
                                     activity: state, panes: tab.panes.count)
        }
    }

    /// The running command ("make dev"), else the program at the prompt ("zsh"), else the
    /// folder the pane started in.
    static func title(row: RemoteTerminalActivity?, pane: LeafPane?) -> String {
        if let command = row?.command, !command.isEmpty { return String(command.prefix(40)) }
        if let process = row?.process, !process.isEmpty { return process }
        if let cwd = pane?.cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty, name != "/" { return name }
        }
        return "Terminal"
    }
}

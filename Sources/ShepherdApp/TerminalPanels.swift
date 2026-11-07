import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

/// Which layout a terminal panel belongs to: a local agent's, or a remote agent's on its host.
struct TerminalPanelKey: Hashable {
    var host: UUID?
    var tab: TabID
}

/// The menu on a panel's tab (NewTerminalMenu), open from + (the selected tab) or a right-click
/// on a tab.
struct TerminalMenuRequest: Equatable {
    let key: TerminalPanelKey
    let tab: PaneID?
    /// Where it hangs, from the strip's leading edge.
    let anchor: CGFloat
}

/// Each agent layout's terminal panel (TerminalSplit, TerminalStates boards): shown or hidden,
/// the tab on screen, maximized, and what its terminals run. The terminals themselves stay the
/// layout's leaves (`PaneNode`): the panel is how the Mac shows them, under the thread. A panel
/// never shows with no terminal in it. Device-local view state; the height persists app-wide
/// (`shepherd.terminalPanelHeight`).
@MainActor
@Observable
final class TerminalPanels {
    struct Panel: Equatable {
        var shown = false
        /// The tab picked last.
        var chosenTab: PaneID?
        var maximized = false
    }

    static let heightKey = "shepherd.terminalPanelHeight"

    private(set) var panels: [TerminalPanelKey: Panel] = [:]
    /// The panel's height; the thread keeps the rest.
    var height: CGFloat {
        didSet { if height != oldValue { defaults.set(Double(height), forKey: Self.heightKey) } }
    }
    /// What each layout's terminals run (`SessionServer.terminalActivity`, or a host's
    /// `RemoteAgentQuery.terminals`), by terminal.
    private(set) var activity: [TerminalPanelKey: [PaneID: RemoteTerminalActivity]] = [:]
    /// Each session's news (`RemoteTerminalActivity.news`) when it was last on screen.
    private(set) var seen: [SessionID: UInt64] = [:]
    /// The menu on a tab, while it is open (NewTerminalMenu): which panel, the tab it acts on,
    /// and where along the strip it hangs.
    var menu: TerminalMenuRequest?
    /// App output tabs (AppsRunning): read-only logs of apps Shepherd runs, beside a layout's
    /// terminals. They are not leaves of the layout: closing one closes the view, never the app.
    private(set) var appTabs: [TerminalPanelKey: [TerminalPanelTab]] = [:]
    /// The app each output tab shows.
    private(set) var appKeys: [PaneID: AppKey] = [:]

    /// The terminals each layout had when last reconciled: one that appears opens the panel.
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
        update(key) { $0.chosenTab = tab.id }
    }

    /// The tab on screen in `layout`.
    func selectedTab(_ key: TerminalPanelKey, layout: PaneNode, thread: PaneID?, focused: PaneID?) -> TerminalPanelTab? {
        TerminalPanel.selected(tabs(key, layout: layout, thread: thread), chosen: panel(key).chosenTab, focused: focused)
    }

    /// The layout's terminals, then its app output tabs.
    func tabs(_ key: TerminalPanelKey, layout: PaneNode, thread: PaneID?) -> [TerminalPanelTab] {
        TerminalPanel.tabs(in: layout, thread: thread) + (appTabs[key] ?? [])
    }

    func appKey(_ tab: PaneID) -> AppKey? { appKeys[tab] }

    /// Shows `app`'s output in `key`'s panel, on its own tab (made the first time), and selects it.
    @discardableResult
    func showApp(_ app: AppKey, title: String, in key: TerminalPanelKey) -> PaneID {
        let id = appTabs[key]?.first { appKeys[$0.id] == app }?.id ?? {
            let tab = TerminalPanelTab(leaf: LeafPane(cwd: "", title: title))
            appTabs[key, default: []].append(tab)
            appKeys[tab.id] = app
            return tab.id
        }()
        update(key) {
            $0.shown = true
            $0.chosenTab = id
        }
        return id
    }

    /// Closes an output tab: the app keeps running. The panel hides with its last tab.
    func closeApp(_ tab: PaneID, in key: TerminalPanelKey, terminals: Int) {
        appTabs[key]?.removeAll { $0.id == tab }
        if appTabs[key]?.isEmpty == true { appTabs[key] = nil }
        appKeys[tab] = nil
        update(key) {
            if $0.chosenTab == tab { $0.chosenTab = nil }
            if terminals == 0 && appTabs[key] == nil {
                $0.shown = false
                $0.maximized = false
            }
        }
    }

    /// Follows the layout: the first time a layout is seen, its panel shows if it has terminals
    /// (as they always showed before the panel); after that, a terminal that appears (⌘D, ⌘J
    /// with none, an agent's `terminal_open`, another device's +) opens the panel on its tab, and
    /// the panel closes with its last terminal. Returns the new terminal to focus, if one appeared.
    @discardableResult
    func reconcile(_ key: TerminalPanelKey, layout: PaneNode, thread: PaneID?) -> PaneID? {
        let tabs = TerminalPanel.tabs(in: layout, thread: thread)
        let terminals = Set(tabs.map(\.id))
        let apps = !(appTabs[key] ?? []).isEmpty
        defer { known[key] = terminals }
        // A panel never shows with no tab in it, whichever way it came to.
        if tabs.isEmpty, !apps, panel(key).shown || panel(key).maximized {
            update(key) {
                $0.shown = false
                $0.maximized = false
            }
        }
        guard let before = known[key] else {
            if !tabs.isEmpty, panels[key] == nil { update(key) { $0.shown = true } }
            return nil
        }
        if !apps, TerminalPanel.closesWithLastTerminal(before: before.count, after: terminals.count) {
            update(key) {
                $0.shown = false
                $0.maximized = false
            }
            return nil
        }
        guard let added = tabs.map(\.id).last(where: { !before.contains($0) }) else { return nil }
        update(key) {
            $0.shown = true
            $0.chosenTab = added
        }
        return added
    }

    func forget(_ key: TerminalPanelKey) {
        panels[key] = nil
        known[key] = nil
        activity[key] = nil
        for tab in appTabs.removeValue(forKey: key) ?? [] { appKeys[tab.id] = nil }
    }

    // MARK: Activity

    func setActivity(_ rows: [RemoteTerminalActivity], for key: TerminalPanelKey) {
        let byTerminal = Dictionary(rows.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        if activity[key] != byTerminal { activity[key] = byTerminal }
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
               host: String?) -> [SHTerminalTab] {
        let rows = activity[key] ?? [:]
        return tabs.map { tab in
            let state: SHTerminalTab.Activity
            if rows[tab.id]?.isRunning == true {
                state = .running
            } else if tab.id != selected?.id || !onScreen, let session = tab.leaf.sessionID, hasUnseen(key, session: session) {
                state = .unseen
            } else {
                state = .idle
            }
            return SHTerminalTab(id: tab.id.rawValue, title: Self.title(row: rows[tab.id], pane: tab.leaf), host: host,
                                 activity: state)
        }
    }

    /// The name Rename tab gave it, else the running command ("make dev"), else the program at
    /// the prompt ("zsh"), else the folder the terminal started in.
    static func title(row: RemoteTerminalActivity?, pane: LeafPane?) -> String {
        if let title = pane?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let command = row?.command, !command.isEmpty { return String(command.prefix(40)) }
        if let process = row?.process, !process.isEmpty { return process }
        if let cwd = pane?.cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty, name != "/" { return name }
        }
        return "Terminal"
    }
}

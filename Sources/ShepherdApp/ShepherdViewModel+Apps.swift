import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Run and Stop for an app (AppsSettings, AppsRunning boards): an app runs as a terminal tab
/// under a thread, named for the app; a browser app's page opens in that thread's Browser once
/// its address answers. Stop closes the tab, which ends the command.
extension ShepherdViewModel {
    /// The thread an app runs under: the selected thread when it is on this Mac and in the app's
    /// space (any space for This Mac's apps), else the space's latest thread. Nil when the space
    /// has none.
    func appThread(for scope: AppScope) -> Agent? {
        let visible = Set(state.spaces.filter { !$0.hidden }.map(\.id))
        func eligible(_ agent: Agent) -> Bool {
            guard visible.contains(agent.spaceID), design(drawnBy: agent) == nil else { return false }
            if case .space(let id) = scope { return agent.spaceID == id }
            return true
        }
        if selectedRemoteAgent == nil, let agent = selectedAgent, eligible(agent) { return agent }
        return state.agents.last(where: eligible)
    }

    /// Why Run is off for `scope`, as its tooltip; nil when it can run.
    func appRunUnavailable(_ scope: AppScope) -> String? {
        guard appThread(for: scope) == nil else { return nil }
        if case .space(let id) = scope, let space = state.spaces.first(where: { $0.id == id }) {
            return "Start a thread in \(space.name) to run its apps"
        }
        return "Start a thread to run apps"
    }

    func runApp(_ app: AppDefinition, key: AppKey) {
        guard apps.run(key) == nil, !apps.starting.contains(key) else { return }
        guard let agent = appThread(for: key.scope) else { NSSound.beep(); return }
        apps.starting.insert(key)
        let root: String? = if case .space = key.scope { agentCwd(agent) } else { nil }
        let directory = app.directory(root: root, home: apps.home)
        let agentID = agent.id
        openTerminalPane(for: agentID, cwd: directory, command: app.command, title: app.name, start: true) { [weak self] outcome in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apps.starting.remove(key)
                switch outcome {
                case .opened(let info):
                    self.apps.setRun(AppRun(agentID: agentID, paneID: info.id), for: key)
                    if let url = app.url {
                        self.showSidePane(.local(agentID), tab: .browser)
                        self.browsers.session(for: agentID).wait(for: url)
                    }
                case .failed(_, let message):
                    self.apps.problem = "Couldn’t run \(app.name): \(message)"
                default:
                    break
                }
            }
        }
    }

    /// Stop: closes the app's terminal tab and ends what it runs.
    func stopApp(_ key: AppKey) {
        guard let run = apps.run(key) else { return }
        if let sessionID = state.tabs.lazy.compactMap({ $0.layout.leaf(withID: run.paneID) }).first?.sessionID {
            server.killSession(sessionID)
        }
        _ = closeLocalPane(run.paneID)
        apps.setRun(nil, for: key)
    }

    /// Runs end with their tab: closed by hand, by Stop, or by its shell exiting.
    func pruneAppRuns() {
        guard !apps.runs.isEmpty else { return }
        let live = Set(state.tabs.flatMap { $0.layout.leaves.map(\.id) })
        apps.prune { live.contains($0) }
    }
}

/// The quick actions a thread header or New thread offers for one space (AppsQuickAction,
/// AppsNewThread, AppsRunning boards). A plain value: the header compares it.
struct QuickApps: Equatable {
    struct Item: Equatable, Identifiable {
        let key: AppKey
        let app: AppDefinition
        let running: Bool
        /// Why Run is off (no thread to run under); nil when it can run.
        var unavailable: String?
        var id: AppKey { key }
        /// "Browser tab", "Terminal", "Its own window".
        var place: String {
            switch app.opens {
            case .browser: "Browser tab"
            case .terminal: "Terminal"
            case .window: "Its own window"
            }
        }
        /// ":3000" beside a running browser app's name.
        var port: String? { app.url?.port.map { ":\($0)" } }
    }

    let space: String
    let items: [Item]
    /// What the header's button shows: the first running app, else the first quick action.
    var primary: Item { items.first(where: \.running) ?? items[0] }
}

extension ShepherdViewModel {
    /// The quick actions of `spaceID`'s apps and This Mac's; nil when there are none.
    func quickApps(in spaceID: SpaceID?) -> QuickApps? {
        guard let spaceID, let space = state.spaces.first(where: { $0.id == spaceID }), !space.hidden else { return nil }
        let items = apps.apps(in: spaceID).filter(\.app.quickAction).map {
            QuickApps.Item(key: $0.key, app: $0.app, running: apps.run($0.key) != nil, unavailable: appRunUnavailable($0.key.scope))
        }
        return items.isEmpty ? nil : QuickApps(space: space.name, items: items)
    }

    /// Add or edit apps…: Settings › Apps.
    func openAppsSettings() {
        adoptSettingsHost(nil)
        settingsSection = .apps
        showSettings = true
    }

    /// A quick action's Run: on the thread on screen when it is in the app's space (`appThread`).
    func runQuickApp(_ key: AppKey) {
        let space: SpaceID? = if case .space(let id) = key.scope { id } else { nil }
        guard let app = apps.apps(in: space).first(where: { $0.key == key })?.app else { return }
        runApp(app, key: key)
    }
}

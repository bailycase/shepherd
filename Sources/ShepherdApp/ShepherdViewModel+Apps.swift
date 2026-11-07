import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Run and Stop for an app (AppsSettings, AppsRunning boards). Shepherd runs it in the
/// background (`AppProcesses`, owned by the server); no thread or terminal owns it. Its output
/// shows as a read-only tab in a thread's terminal panel, and a browser app's page opens in that
/// thread's Browser once its address answers.
extension ShepherdViewModel {
    /// Wires the server's app processes to Settings, the header and New thread. Called once.
    func installApps() {
        server.apps.onChange = { [weak self] snapshots in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apps.adopt(snapshots)
                    // A page waiting on an app that ended never answers: stop waiting.
                    for (key, thread) in self.appPageWaits where snapshots[key]?.status.isLive != true {
                        self.browsers.existing(thread)?.stopWaiting()
                        self.appPageWaits[key] = nil
                    }
                }
            }
        }
    }

    /// The thread on screen on this Mac when it is in `scope`'s space (any space for This Mac's
    /// apps): its output and page show there.
    func appThreadOnScreen(for scope: AppScope) -> Agent? {
        guard selectedRemoteAgent == nil, destination == nil, let agent = selectedAgent, design(drawnBy: agent) == nil else { return nil }
        if case .space(let id) = scope, agent.spaceID != id { return nil }
        return agent
    }

    /// Where an app runs: a space's under the thread on screen when it is in that space (so a
    /// worktree thread runs its own copy), else under the space's folder; This Mac's from home.
    func appDirectory(_ app: AppDefinition, key: AppKey, thread: Agent?) -> String? {
        switch key.scope {
        case .mac: return app.directory(root: nil, home: apps.home)
        case .space(let id):
            guard let space = state.spaces.first(where: { $0.id == id }) else { return nil }
            let root = thread.map(agentCwd) ?? HooksModel.expand(space.path, home: apps.home)
            return app.directory(root: root, home: apps.home)
        }
    }

    /// Run: starts the app in the background. From a thread (`showOutput`), its output opens in
    /// that thread's panel and its page in its Browser.
    func runApp(_ app: AppDefinition, key: AppKey, showOutput: Bool = false) {
        guard apps.process(key)?.status.isLive != true else { return }
        let thread = appThreadOnScreen(for: key.scope)
        guard let directory = appDirectory(app, key: key, thread: thread) else { NSSound.beep(); return }
        server.apps.start(key, command: app.command, directory: directory, address: app.url) { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .failed(let why) = snapshot.status {
                        self.apps.problem = "Couldn’t run \(app.name): \(why)"
                        return
                    }
                    guard showOutput, let thread else { return }
                    self.showAppOutput(key, title: app.name, in: thread)
                    if let url = app.url {
                        self.showSidePane(.local(thread.id), tab: .browser)
                        self.browsers.session(for: thread.id).wait(for: url)
                        self.appPageWaits[key] = thread.id
                    }
                }
            }
        }
    }

    /// Restart, after an app exited: the same command in the same folder.
    func restartApp(_ key: AppKey) {
        guard let process = apps.process(key), !process.status.isLive else { return }
        let address = apps.apps(in: key.spaceID).first { $0.key == key }?.app.url
        server.apps.start(key, command: process.command, directory: process.directory, address: address)
    }

    /// Stop: SIGTERM to the app's process group, SIGKILL after a grace period.
    func stopApp(_ key: AppKey) {
        server.apps.stop(key)
    }

    /// The app's output in `thread`'s terminal panel, on its own tab.
    func showAppOutput(_ key: AppKey, title: String, in thread: Agent) {
        terminalPanels.showApp(key, title: title, in: TerminalPanelKey(host: nil, tab: thread.tabID))
    }

    /// The header's running app: its output in the thread on screen.
    func showAppOutput(_ key: AppKey) {
        guard let thread = appThreadOnScreen(for: key.scope) else { NSSound.beep(); return }
        showAppOutput(key, title: key.name, in: thread)
    }
}

extension AppKey {
    var spaceID: SpaceID? { if case .space(let id) = scope { id } else { nil } }
}

/// The quick actions a thread header or New thread offers for one space (AppsQuickAction,
/// AppsNewThread, AppsRunning boards). A plain value: the header compares it.
struct QuickApps: Equatable {
    struct Item: Equatable, Identifiable {
        let key: AppKey
        let app: AppDefinition
        /// What it is doing; nil before it first runs.
        let status: AppStatus?
        let port: Int?
        var running: Bool { status?.isLive == true }
        var id: AppKey { key }
        /// "Browser tab", "Terminal", "Its own window".
        var place: String {
            switch app.opens {
            case .browser: "Browser tab"
            case .terminal: "Terminal"
            case .window: "Its own window"
            }
        }
        /// ":3000" beside a running app's name.
        var portLabel: String? { port.map { ":\($0)" } }
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
            let process = apps.process($0.key)
            return QuickApps.Item(key: $0.key, app: $0.app, status: process?.status, port: process?.port)
        }
        return items.isEmpty ? nil : QuickApps(space: space.name, items: items)
    }

    /// Add or edit apps…: Settings › Apps.
    func openAppsSettings() {
        adoptSettingsHost(nil)
        settingsSection = .apps
        showSettings = true
    }

    /// A quick action's Run (`showOutput` from a thread's header).
    func runQuickApp(_ key: AppKey, showOutput: Bool = false) {
        guard let app = apps.apps(in: key.spaceID).first(where: { $0.key == key })?.app else { return }
        runApp(app, key: key, showOutput: showOutput)
    }
}

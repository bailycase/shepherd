import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Apps (SettingsApps, AppsSettings boards): a Mac's apps with their runs, one app's output,
// and Run, Stop and Restart pressed for real. The host keeps its runs and changes them as it is asked
// (`FixtureHostData.accepts`); the check compares what it received. Made-up names throughout.
extension FixtureCatalog {
    static var apps: [FixtureScreen] {
        let studio = AppsFixtureData.studio
        func app(_ id: String) -> MobileRoute { .settings(.app(host: studio, id: id)) }
        return [
            FixtureScreen(name: "settings-apps", hosts: AppsFixtureData.hosts(), routes: [.settings(.apps)], tab: .settings),
            // A running app with its output, an exited one (Restart), and one that never ran.
            FixtureScreen(name: "settings-app", hosts: AppsFixtureData.hosts(), routes: [.settings(.apps), app("space-acme-web/Web app")], tab: .settings),
            FixtureScreen(name: "settings-app-exited", hosts: AppsFixtureData.hosts(), routes: [.settings(.apps), app("space-acme-web/Storybook")], tab: .settings),
            FixtureScreen(name: "settings-app-idle", hosts: AppsFixtureData.hosts(), routes: [.settings(.apps), app("space-acme-web/iOS app")], tab: .settings),
            // A Mac too old for apps.v2, and one that is offline, beside one that serves them.
            FixtureScreen(name: "settings-apps-hosts", hosts: AppsFixtureData.hosts(withOthers: true), routes: [.settings(.apps)], tab: .settings),
            FixtureScreen(name: "settings-apps-hosts-lower", hosts: AppsFixtureData.hosts(withOthers: true), routes: [.settings(.apps)], tab: .settings,
                          prepare: { _ in await TriggerFlowCheck.scrollDown(holding: nil) }),
            FixtureScreen(name: "settings-pad-apps", hosts: AppsFixtureData.hosts(), routes: [.settings(.root)], tab: .settings,
                          prepare: { app in app.navigator.settingsSelection.page = .apps }),
            FixtureScreen(name: "settings-apps-actions", hosts: AppsFixtureData.hosts(), routes: [.settings(.apps)], tab: .settings,
                          prepare: { app in await AppsFixtureData.press(app) }),
        ]
    }
}

enum AppsFixtureData {
    static let studio = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A1")!
    static let older = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A2")!
    static let offline = UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A3")!
    static let web = Space(id: SpaceID(rawValue: "space-acme-web"), name: "acme-web", path: "~/code/acme-web")
    static let api = Space(id: SpaceID(rawValue: "space-acme-api"), name: "acme-api", path: "~/code/acme-api")
    static let quiet = Space(id: SpaceID(rawValue: "space-acme-docs"), name: "acme-docs", path: "~/code/acme-docs")

    static let own = [
        AppDefinition(name: "Postgres", command: "postgres -D ~/pg", agents: true),
        AppDefinition(name: "Docs", command: "make docs"),
    ]
    static let webApps = [
        AppDefinition(name: "Web app", command: "pnpm dev", folder: "apps/web", opens: .browser, address: "http://localhost:3000", quickAction: true),
        AppDefinition(name: "Storybook", command: "pnpm storybook", opens: .browser, address: "http://localhost:6006", quickAction: true),
        AppDefinition(name: "iOS app", command: "xcodebuild -scheme Acme && xcrun simctl launch booted com.acme.app", opens: .window, quickAction: true),
    ]
    static let apiApps = [
        AppDefinition(name: "API", command: "go run ./cmd/api", opens: .browser, address: "http://localhost:8080"),
        AppDefinition(name: "Refund worker", command: "go run ./cmd/worker"),
    ]

    static func processes() -> [RemoteAppProcess] {
        [
            RemoteAppProcess(spaceID: nil, name: "Postgres",
                             run: RemoteAppRun(status: .running, port: 5432, command: "postgres -D ~/pg", directory: "~/pg", revision: 4)),
            RemoteAppProcess(spaceID: web.id, name: "Web app",
                             run: RemoteAppRun(status: .running, port: 3000, command: "pnpm dev", directory: "~/code/acme-web/apps/web", revision: 9)),
            RemoteAppProcess(spaceID: web.id, name: "Storybook",
                             run: RemoteAppRun(status: .exited(code: 1), command: "pnpm storybook", directory: "~/code/acme-web", revision: 6)),
            RemoteAppProcess(spaceID: api.id, name: "API",
                             run: RemoteAppRun(status: .failed("Its folder doesn’t exist."), command: "go run ./cmd/api", directory: "~/code/acme-api")),
        ]
    }

    static let output: [String: [String]] = [
        "acme-web/Web app": ["$ pnpm dev", "", "> acme-web@0.4.0 dev", "> next dev", "", "  ▲ Next.js 15.1", "  - Local: http://localhost:3000", "",
                             " ✓ Ready in 1.2s", " GET /refunds 200 in 84ms", " GET /api/refunds 200 in 31ms"],
        "acme-web/Storybook": ["$ pnpm storybook", "storybook v8.4", "Error: Port 6006 is already in use", "    at listen (server.js:41:11)", "pnpm: exited with code 1"],
        "mac/Postgres": ["LOG:  database system is ready to accept connections"],
    ]

    /// The Mac with its apps. `withOthers` adds one too old for `apps.v2` and one offline.
    static func hosts(withOthers: Bool = false) -> [FixtureHostData] {
        let state = ShepherdState(spaces: [web, api, quiet])
        let keep = AppsHost()
        var main = FixtureHostData(id: studio, name: "studio-mac", state: state)
        main.reply = { request in keep.answer(request) }
        main.accepts = { request in keep.accept(request) }
        guard withOthers else { return [main] }
        var old = FixtureHostData(id: older, name: "build-mac", state: ShepherdState())
        old.capabilities = old.defaultCapabilities.filter { $0 != RemoteProtocol.appsV2Capability }
        return [main, old, FixtureHostData(id: offline, name: "laptop", state: ShepherdState(), online: false)]
    }

    /// The host's runs, changed as the app asks.
    final class AppsHost: @unchecked Sendable {
        private let lock = NSLock()
        private var runs = AppsFixtureData.processes()

        func answer(_ request: RemoteRequest) -> RemoteReply? {
            guard case .apps(let id, let command) = request else { return nil }
            return lock.withLock { .apps(id: id, result: result(command)) }
        }

        func accept(_ request: RemoteRequest) -> RemoteReply? {
            guard case .apps(let id, let command) = request else { return nil }
            return lock.withLock { () -> RemoteReply? in
                func set(_ space: SpaceID?, _ name: String, _ run: RemoteAppRun) {
                    runs.removeAll { $0.spaceID == space && $0.name == name }
                    runs.append(RemoteAppProcess(spaceID: space, name: name, run: run))
                }
                switch command {
                case .run(let space, let name, _, _), .restart(let space, let name):
                    set(space, name, RemoteAppRun(status: .running, command: name, directory: "~", revision: 1))
                case .stop(let space, let name, _):
                    set(space, name, RemoteAppRun(status: .exited(code: 143), command: name, directory: "~", revision: 2))
                default: return nil
                }
                return .apps(id: id, result: result(command))
            }
        }

        private func result(_ command: RemoteAppsRequest) -> RemoteAppsResult {
            let found = AppsFixtureData.apps(command.spaceID)
            var lines: [String]?
            if case .output(let space, let name, _) = command { lines = AppsFixtureData.output[(space?.rawValue.replacingOccurrences(of: "space-", with: "") ?? "mac") + "/" + name] ?? [] }
            // The page reads runs from `processes`, so a listed app carries none.
            let mine = found.map { RemoteApp(app: $0.app, mac: $0.mac) }
            return RemoteAppsResult(space: "", apps: mine, processes: command == .processes ? runs : nil, lines: lines)
        }
    }

    static func apps(_ space: SpaceID?) -> [(app: AppDefinition, mac: Bool)] {
        let theirs: [AppDefinition] = switch space {
        case web.id?: webApps
        case api.id?: apiApps
        default: []
        }
        return theirs.map { ($0, false) } + own.map { ($0, true) }
    }

    /// Run, Stop and Restart pressed through the accessibility tree as VoiceOver presses them: what the host
    /// received is each app's own request, a space's apps with their space and the Mac's own with none.
    @MainActor static func press(_ app: MobileApp) async {
        let host = FixtureHost.running(studio)
        let accepted = { host?.accepted.count ?? 0 }
        func check(_ ok: Bool, _ what: String) { FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)") }
        SidebarAutomationsCheck.enableAccessibility()
        await FixtureCheck.wait("the Web app row's button", seconds: 12) { TriggerFlowCheck.element("Stop Web app", prefix: false) != nil }
        let steps: [(label: String, request: RemoteAppsRequest)] = [
            ("Restart Storybook", .restart(spaceID: web.id, name: "Storybook")),
            ("Stop Web app", .stop(spaceID: web.id, name: "Web app", mac: false)),
            ("Run iOS app", .run(spaceID: web.id, name: "iOS app", mac: false, agentID: nil)),
            ("Stop Postgres", .stop(spaceID: nil, name: "Postgres", mac: true)),
            ("Run Docs", .run(spaceID: nil, name: "Docs", mac: true, agentID: nil)),
        ]
        for (index, step) in steps.enumerated() {
            await TriggerFlowCheck.press(step.label)
            await FixtureCheck.wait("\(step.label) to reach the host", seconds: 8) { accepted() == index + 1 }
        }
        let received = host?.accepted.compactMap { request -> RemoteAppsRequest? in if case .apps(_, let command) = request { command } else { nil } }
        check(received == steps.map(\.request), "Run, Stop and Restart send each app's own request, with its space or none")
        // The page reads the runs again: the words follow the host.
        await FixtureCheck.wait("Web app to read as exited", seconds: 8) { TriggerFlowCheck.element("Restart Web app", prefix: false) != nil }
        check(TriggerFlowCheck.element("Stop iOS app", prefix: false) != nil && TriggerFlowCheck.element("Restart Postgres", prefix: false) != nil,
              "each button follows the run the host now reports")
    }
}

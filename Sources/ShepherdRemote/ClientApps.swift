import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

// Settings › Apps on the iPhone and the iPad (SettingsApps, AppsSettings boards): every app on a host,
// its run and its output, with Run, Stop and Restart, over `apps.v2` (`processes`, `output`, `restart`,
// and a nil-space `run` and `stop` for the host's own apps). Definitions are read from `list` and never
// written: that needs a later request (`apps.v3`). The model holds what the pages draw, derived once per
// answer, and every rule they follow, so the pages only draw.

/// What Settings › Apps reads and changes a host's apps through: its `RemoteHostClient`, or a stand-in in tests.
public protocol AppsClient: AnyObject, Sendable {
    func apps(_ request: RemoteAppsRequest) async throws -> RemoteAppsResult
}

extension RemoteHostClient: AppsClient {}

/// One app on a host, as a row draws it.
public struct AppRowValue: Equatable, Identifiable, Sendable {
    /// Unique on the host: its space (or "mac") and its name.
    public var id: String
    /// Its space; nil for one of the host's own, saved for every space.
    public var spaceID: SpaceID?
    public var name: String
    public var command: String
    /// "Browser tab · localhost:3000", "Terminal", "Its own window".
    public var place: String
    public var quickAction: Bool
    public var agents: Bool
    /// False for a run whose app was removed from its file since: it can be stopped or restarted, not run.
    public var defined: Bool
    public var run: RemoteAppRun?

    /// "Browser tab · localhost:3000 · pnpm dev".
    public var subtitle: String { command.isEmpty ? place : place + " · " + command }
    /// What its button does next.
    public var action: RemoteQuickApps.Action { RemoteQuickApps.action(run) }
    /// The button's word.
    public var actionTitle: String {
        switch action {
        case .run: "Run"
        case .stop: "Stop"
        case .restart: "Restart"
        }
    }
    /// "Running · :3000", "Exited (code 1)", or why it couldn't start; nil before it first runs.
    public var status: String? { run.map(AppsPresentation.words) }
    /// The dot's tone; nil before it first runs.
    public var tone: AppsPresentation.Tone? { run.map(AppsPresentation.tone) }
    /// Stop was asked for and it hasn't ended yet: its button waits.
    public var stopping: Bool { run?.stopping == true && run?.isLive == true }
    /// "Web app, Running · :3000": what the row says as one element.
    public var accessibilityLabel: String { [name, status].compactMap { $0 }.joined(separator: ", ") }
}

/// One section of the page: a host's own apps, or a space's.
public struct AppGroupValue: Equatable, Identifiable, Sendable {
    public var id: String
    /// "On studio-mac", or the space's name.
    public var title: String
    public var footnote: String
    public var rows: [AppRowValue]
}

public struct AppsPage: Equatable, Sendable {
    public var groups: [AppGroupValue]

    public func row(_ id: String) -> AppRowValue? { groups.lazy.flatMap(\.rows).first { $0.id == id } }
}

/// A space's apps as `list` answered them, with the space's name.
public struct SpaceApps: Equatable, Sendable {
    public var space: SpaceID
    public var name: String
    public var apps: [AppDefinition]

    public init(space: SpaceID, name: String, apps: [AppDefinition]) {
        self.space = space
        self.name = name
        self.apps = apps
    }
}

public enum AppsPresentation {
    /// A run's tone, named as an `AgentState` raw value so this module needs no ShepherdUI.
    public enum Tone: String, Sendable, Hashable {
        case running, done, idle, failed
    }

    private static let file = ".shepherd/apps.json"

    /// The page's groups: the host's own apps (always, empty or not), then each space that has an app
    /// or a run, in the host's order. A run whose app is gone from its file still shows, under its space.
    public static func page(host: String, own: [AppDefinition], spaces: [SpaceApps], runs: [RemoteAppProcess]) -> AppsPage {
        func rows(_ definitions: [AppDefinition], scope: SpaceID?) -> [AppRowValue] {
            let mine = runs.filter { $0.spaceID == scope }
            let known = definitions.map { definition in
                row(definition, scope: scope, run: mine.first { $0.name == definition.name }?.run, defined: true)
            }
            let gone = mine.filter { run in !definitions.contains { $0.name == run.name } }.map { run in
                row(AppDefinition(name: run.name, command: run.run.command ?? ""), scope: scope, run: run.run, defined: false)
            }
            return known + gone
        }
        var groups = [AppGroupValue(id: "mac", title: "On \(host)", footnote: "Saved in ~/\(file). These are in every space.",
                                    rows: rows(own, scope: nil))]
        for space in spaces {
            let rows = rows(space.apps, scope: space.space)
            guard !rows.isEmpty else { continue }
            groups.append(AppGroupValue(
                id: space.space.rawValue, title: space.name,
                footnote: "Saved in \(file) in the space, so everyone who opens it gets them. Quick actions show in the thread header while you are in \(space.name).",
                rows: rows))
        }
        return AppsPage(groups: groups)
    }

    private static func row(_ app: AppDefinition, scope: SpaceID?, run: RemoteAppRun?, defined: Bool) -> AppRowValue {
        AppRowValue(id: (scope?.rawValue ?? "mac") + "/" + app.name, spaceID: scope, name: app.name, command: app.command,
                    place: place(app), quickAction: app.quickAction, agents: app.agents, defined: defined, run: run)
    }

    /// "Browser tab · localhost:3000", "Terminal", "Its own window".
    public static func place(_ app: AppDefinition) -> String {
        guard let url = app.url, let host = url.host else { return RemoteQuickApps.place(app) }
        return "Browser tab · " + host + (url.port.map { ":\($0)" } ?? "")
    }

    /// Starting…, Running · :3000, Stopping…, Exited (code 1), or why it couldn't start.
    public static func words(_ run: RemoteAppRun) -> String {
        switch run.status {
        case .starting: run.stopping ? "Stopping…" : "Starting…"
        case .running: run.stopping ? "Stopping…" : ["Running", RemoteQuickApps.portLabel(run)].compactMap { $0 }.joined(separator: " · ")
        case .exited(let code): "Exited (code \(code))"
        case .failed(let why): why
        }
    }

    public static func tone(_ run: RemoteAppRun) -> Tone {
        switch run.status {
        case .starting: .running
        case .running: run.stopping ? .running : .done
        case .exited(let code): code == 0 || run.stopping ? .idle : .failed
        case .failed: .failed
        }
    }

    /// What the row's button sends: the host's own apps with no space (`apps.v2`), a space's with it.
    public static func request(_ action: RemoteQuickApps.Action, for row: AppRowValue) -> RemoteAppsRequest {
        switch action {
        case .run: .run(spaceID: row.spaceID, name: row.name, mac: row.spaceID == nil, agentID: nil)
        case .stop: .stop(spaceID: row.spaceID, name: row.name, mac: row.spaceID == nil)
        case .restart: .restart(spaceID: row.spaceID, name: row.name)
        }
    }
}

/// Every host's apps for Settings: what each host's files hold and what is running, read when the page
/// shows and the runs again every few seconds, and changed one app at a time.
@MainActor
@Observable
public final class ClientApps {
    public enum State: Equatable, Sendable {
        case offline
        /// Its Shepherd predates `apps.v2`.
        case unsupported
        case loading
        case loaded(AppsPage)
        case failed(String)

        public var page: AppsPage? { if case .loaded(let page) = self { page } else { nil } }
    }

    /// What a host's files hold, kept for the runs read again, and the page they make.
    private struct Loaded {
        var spaces: [SpaceApps]
        var page: AppsPage
    }

    private var loaded: [UUID: Loaded] = [:]
    private var failures: [UUID: String] = [:]
    /// The last Run, Stop or Restart a host refused, or a space it couldn't read, said on the page.
    public private(set) var problems: [UUID: String] = [:]
    private var busy: Set<String> = []

    /// How often a shown page reads the runs again, for an app that starts, ends or finds its port.
    // ponytail: a poll; a local client is pushed `appsChanged`, a remote one could be when it matters.
    public static let refresh: Duration = .seconds(3)
    /// The lines of output a screen asks for.
    public static let outputLines = 500

    public init() {}

    public func state(of host: SettingsHost) -> State {
        guard host.isConnected else { return .offline }
        guard host.serves(RemoteProtocol.appsV2Capability) else { return .unsupported }
        if let page = loaded[host.id]?.page { return .loaded(page) }
        return failures[host.id].map(State.failed) ?? .loading
    }

    public func dismissProblem(_ host: SettingsHost) { problems[host.id] = nil }

    public func forget(host id: UUID) {
        loaded[id] = nil
        failures[id] = nil
        problems[id] = nil
    }

    /// Whether the row's own request is on its way to the host: its button waits.
    public func isBusy(_ row: AppRowValue, on host: SettingsHost) -> Bool { busy.contains(host.id.uuidString + "/" + row.id) }

    /// Reads the host's apps from its files, space by space, and every run on it. A space it can't
    /// read is left out and said; a host that can't answer keeps what it showed.
    public func load(_ host: SettingsHost, spaces: [Space]) async {
        guard let client = host.client as? AppsClient, host.serves(RemoteProtocol.appsV2Capability) else { return }
        do {
            let first = try await client.apps(.processes)
            let visible = spaces.filter { !$0.hidden }
            // ponytail: one request per space, all at once; page them if a host ever keeps hundreds.
            let answers = await withTaskGroup(of: (Int, Result<RemoteAppsResult, Error>).self) { group in
                for (index, space) in visible.enumerated() {
                    group.addTask {
                        do { return (index, .success(try await client.apps(.list(spaceID: space.id)))) }
                        catch { return (index, .failure(error)) }
                    }
                }
                var all: [Int: Result<RemoteAppsResult, Error>] = [:]
                for await (index, result) in group { all[index] = result }
                return all
            }
            var found: [SpaceApps] = []
            var unread: String?
            for (index, space) in visible.enumerated() {
                switch answers[index] {
                case .success(let result)?:
                    found.append(SpaceApps(space: space.id, name: space.name, apps: result.apps.filter { !$0.mac }.map(\.app)))
                case .failure(let error)?:
                    unread = unread ?? "Couldn't read the apps in \(space.name): \(settingsProblem(error))"
                case nil: break
                }
            }
            failures[host.id] = nil
            if let unread { problems[host.id] = unread }
            set(host, own: first.apps.map(\.app), spaces: found, runs: first.processes ?? [])
        } catch {
            if loaded[host.id] == nil { failures[host.id] = settingsProblem(error) } else { problems[host.id] = settingsProblem(error) }
        }
    }

    /// Reads every run again, and the host's own apps with them; a host that can't answer keeps what it showed.
    public func poll(_ host: SettingsHost) async {
        guard let client = host.client as? AppsClient, host.serves(RemoteProtocol.appsV2Capability), let spaces = loaded[host.id]?.spaces,
              let result = try? await client.apps(.processes) else { return }
        set(host, own: result.apps.map(\.app), spaces: spaces, runs: result.processes ?? [])
    }

    /// Runs, stops or restarts one app, then reads the runs. A refusal is the page's problem, under the app's name.
    public func perform(_ row: AppRowValue, on host: SettingsHost) async {
        guard let client = host.client as? AppsClient, host.serves(RemoteProtocol.appsV2Capability) else { return }
        let key = host.id.uuidString + "/" + row.id
        guard busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        do {
            _ = try await client.apps(AppsPresentation.request(row.action, for: row))
            problems[host.id] = nil
        } catch {
            problems[host.id] = "\(row.name): \(settingsProblem(error))"
        }
        await poll(host)
    }

    /// The app's last lines of output, the line still being written last.
    public func output(of row: AppRowValue, on host: SettingsHost) async throws -> [String] {
        guard let client = host.client as? AppsClient else {
            throw RemoteHostClientError.rejected(code: "offline", message: "The host is offline. Try again once it's back.")
        }
        return try await client.apps(.output(spaceID: row.spaceID, name: row.name, tail: Self.outputLines)).lines ?? []
    }

    private func set(_ host: SettingsHost, own: [AppDefinition], spaces: [SpaceApps], runs: [RemoteAppProcess]) {
        let page = AppsPresentation.page(host: host.name, own: own, spaces: spaces, runs: runs)
        if loaded[host.id]?.page != page { loaded[host.id] = Loaded(spaces: spaces, page: page) }
    }
}

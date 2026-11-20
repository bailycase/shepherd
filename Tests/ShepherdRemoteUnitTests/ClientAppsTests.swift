import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// A host's apps as the phone reads them: definitions per space and the host's own, every run in
/// memory, every request recorded, and a Run that can be refused.
final class FakeAppsHost: SettingsClient, AppsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [RemoteAppsRequest] = []
    private var runs: [RemoteAppProcess]
    let own: [AppDefinition]
    let spaces: [SpaceID: [AppDefinition]]
    var refusesRun = false
    var unreadable: Set<SpaceID> = []

    init(own: [AppDefinition], spaces: [SpaceID: [AppDefinition]], runs: [RemoteAppProcess] = []) {
        self.own = own
        self.spaces = spaces
        self.runs = runs
    }

    var requests: [RemoteAppsRequest] { lock.withLock { log } }

    func apps(_ request: RemoteAppsRequest) async throws -> RemoteAppsResult {
        try lock.withLock {
            log.append(request)
            if case .list(let space) = request, unreadable.contains(space) {
                throw RemoteHostClientError.rejected(code: "no_such_space", message: "That space isn't on this host.")
            }
            var lines: [String]?
            switch request {
            case .run(let space, let name, _, _):
                if refusesRun { throw RemoteHostClientError.rejected(code: "start_failed", message: "Its folder doesn’t exist.") }
                set(RemoteAppRun(status: .running, port: 3000, command: "pnpm dev", directory: "/Users/sam/acme-web", revision: 1), space: space, name: name)
            case .stop(let space, let name, _):
                set(RemoteAppRun(status: .exited(code: 143), command: "pnpm dev", directory: "/Users/sam/acme-web", revision: 2), space: space, name: name)
            case .restart(let space, let name):
                set(RemoteAppRun(status: .running, port: 3000, command: "pnpm dev", directory: "/Users/sam/acme-web", revision: 3), space: space, name: name)
            case .output(_, _, let tail):
                lines = Array(["pnpm dev", "ready on :3000", "GET / 200"].suffix(tail))
            case .list, .processes: break
            }
            let space = request.spaceID
            let definitions = (space.flatMap { spaces[$0] } ?? []).map { RemoteApp(app: $0, mac: false) } + own.map { RemoteApp(app: $0, mac: true) }
            return RemoteAppsResult(space: "", apps: space == nil ? own.map { RemoteApp(app: $0, mac: true) } : definitions,
                                    processes: request == .processes ? runs : nil, lines: lines)
        }
    }

    private func set(_ run: RemoteAppRun, space: SpaceID?, name: String) {
        runs.removeAll { $0.spaceID == space && $0.name == name }
        runs.append(RemoteAppProcess(spaceID: space, name: name, run: run))
    }

    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult { throw CancellationError() }
    func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings { HostSettings() }
    func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot { InstructionsSnapshot(directory: "~/i") }
    func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot { SuggestionsSnapshot() }
}

@MainActor
@Suite("Client apps")
struct ClientAppsTests {
    static let web = SpaceID(rawValue: "acme-web")
    static let api = SpaceID(rawValue: "acme-api")
    static let spaces = [Space(id: web, name: "acme-web", path: "/Users/sam/acme-web"), Space(id: api, name: "acme-api", path: "/Users/sam/acme-api")]
    static let webApp = AppDefinition(name: "Web app", command: "pnpm dev", opens: .browser, address: "http://localhost:3000", quickAction: true)
    static let storybook = AppDefinition(name: "Storybook", command: "pnpm storybook")
    static let postgres = AppDefinition(name: "Postgres", command: "postgres -D ~/pg", agents: true)

    static func fake(runs: [RemoteAppProcess] = []) -> FakeAppsHost {
        FakeAppsHost(own: [postgres], spaces: [web: [webApp, storybook], api: []], runs: runs)
    }

    static func host(_ client: (any SettingsClient)?, capable: Bool = true) -> SettingsHost {
        SettingsHost(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "studio-mac", client: client,
                     capabilities: capable ? [RemoteProtocol.appsV2Capability] : [RemoteProtocol.appsCapability])
    }

    @Test func aHostsOwnAppsComeFirstThenEachSpaceThatHasAppsWithTheirRuns() async throws {
        let fake = Self.fake(runs: [RemoteAppProcess(spaceID: Self.web, name: "Web app", run: RemoteAppRun(status: .running, port: 3000))])
        let model = ClientApps()
        let host = Self.host(fake)
        #expect(model.state(of: host) == .loading)
        await model.load(host, spaces: Self.spaces)
        let page = try #require(model.state(of: host).page)
        #expect(page.groups.map(\.title) == ["On studio-mac", "acme-web"], "acme-api has no apps")
        #expect(page.groups[0].rows.map(\.name) == ["Postgres"])
        let web = try #require(page.row("acme-web/Web app"))
        #expect(web.status == "Running · :3000" && web.tone == .done && web.actionTitle == "Stop")
        #expect(web.subtitle == "Browser tab · localhost:3000 · pnpm dev" && web.quickAction)
        let idle = try #require(page.row("acme-web/Storybook"))
        #expect(idle.status == nil && idle.actionTitle == "Run" && idle.subtitle == "Terminal · pnpm storybook")
        #expect(page.row("mac/Postgres")?.agents == true)
    }

    @Test(arguments: [
        (RemoteAppRun?.none, "Run", String?.none),
        (RemoteAppRun(status: .starting), "Stop", "Starting…"),
        (RemoteAppRun(status: .running, port: 3000, stopping: true), "Stop", "Stopping…"),
        (RemoteAppRun(status: .exited(code: 1)), "Restart", "Exited (code 1)"),
        (RemoteAppRun(status: .failed("Its folder doesn’t exist.")), "Run", "Its folder doesn’t exist."),
    ])
    func eachRunSaysWhatItDoesAndWhatItsButtonDoesNext(run: RemoteAppRun?, button: String, words: String?) {
        let page = AppsPresentation.page(host: "studio-mac", own: [Self.postgres], spaces: [],
                                         runs: run.map { [RemoteAppProcess(spaceID: nil, name: "Postgres", run: $0)] } ?? [])
        let row = page.groups[0].rows[0]
        #expect(row.actionTitle == button)
        #expect(row.status == words)
    }

    @Test func aRunWhoseAppWasRemovedStillShowsButCantBeStoppedOrRunBecauseTheHostRefusesBoth() {
        let gone = RemoteAppProcess(spaceID: Self.web, name: "Old", run: RemoteAppRun(status: .running, command: "make old"))
        let page = AppsPresentation.page(host: "studio-mac", own: [], spaces: [SpaceApps(space: Self.web, name: "acme-web", apps: [])], runs: [gone])
        let row = page.row("acme-web/Old")
        #expect(row?.defined == false && row?.actionTitle == "Stop" && row?.subtitle == "Terminal · make old")
        #expect(row?.actionBlocked == "Removed from its file, so it can't be stopped from here.")
        #expect(page.groups[0].rows.isEmpty, "the host's own group is shown empty")
        let ended = AppsPresentation.page(host: "studio-mac", own: [], spaces: [SpaceApps(space: Self.web, name: "acme-web", apps: [])],
                                          runs: [RemoteAppProcess(spaceID: Self.web, name: "Old", run: RemoteAppRun(status: .exited(code: 1), command: "make old"))])
        #expect(ended.row("acme-web/Old")?.actionTitle == "Restart" && ended.row("acme-web/Old")?.actionBlocked == nil, "the host restarts from the run, not the file")
    }

    @Test func stoppingARunWhoseAppWasRemovedSendsNothing() async throws {
        let gone = RemoteAppProcess(spaceID: Self.web, name: "Old", run: RemoteAppRun(status: .running, command: "make old"))
        let fake = Self.fake(runs: [gone])
        let model = ClientApps()
        let host = Self.host(fake)
        await model.load(host, spaces: Self.spaces)
        let row = try #require(model.state(of: host).page?.row("acme-web/Old"))
        #expect(row.actionBlocked != nil)
        let before = fake.requests.count
        await model.perform(row, on: host)
        #expect(fake.requests.count == before, "no stop request goes out")
        #expect(model.problems[host.id] == nil)
    }

    @Test func restartShowsTheCommandItRunsWhenTheDefinitionChangedSinceTheRun() throws {
        let edited = AppDefinition(name: "Storybook", command: "pnpm storybook --ci")
        func row(_ run: RemoteAppRun) throws -> AppRowValue {
            let page = AppsPresentation.page(host: "studio-mac", own: [], spaces: [SpaceApps(space: Self.web, name: "acme-web", apps: [edited])],
                                             runs: [RemoteAppProcess(spaceID: Self.web, name: "Storybook", run: run)])
            return try #require(page.row("acme-web/Storybook"))
        }
        let ended = try row(RemoteAppRun(status: .exited(code: 1), command: "pnpm storybook"))
        #expect(ended.actionTitle == "Restart")
        #expect(ended.subtitle == "Terminal · pnpm storybook --ci", "the definition is the new one")
        #expect(ended.restartCommand == "pnpm storybook", "Restart runs the previous run's")
        #expect(try row(RemoteAppRun(status: .exited(code: 1), command: "pnpm storybook --ci")).restartCommand == nil, "unchanged says nothing more")
        #expect(try row(RemoteAppRun(status: .running, command: "pnpm storybook")).restartCommand == nil, "only an ended run restarts")
        #expect(try row(RemoteAppRun(status: .exited(code: 1))).restartCommand == nil, "no command recorded")
    }

    @Test func runStopAndRestartGoToTheHostWithTheSpaceOrNoneForTheHostsOwn() async throws {
        let fake = Self.fake()
        let model = ClientApps()
        let host = Self.host(fake)
        await model.load(host, spaces: Self.spaces)

        let postgres = try #require(model.state(of: host).page?.row("mac/Postgres"))
        await model.perform(postgres, on: host)
        #expect(fake.requests.contains(.run(spaceID: nil, name: "Postgres", mac: true, agentID: nil)))
        #expect(model.state(of: host).page?.row("mac/Postgres")?.status == "Running · :3000", "the runs are read again after")

        let running = try #require(model.state(of: host).page?.row("mac/Postgres"))
        await model.perform(running, on: host)
        #expect(fake.requests.contains(.stop(spaceID: nil, name: "Postgres", mac: true)))
        let ended = try #require(model.state(of: host).page?.row("mac/Postgres"))
        #expect(ended.actionTitle == "Restart")
        await model.perform(ended, on: host)
        #expect(fake.requests.contains(.restart(spaceID: nil, name: "Postgres")))

        let story = try #require(model.state(of: host).page?.row("acme-web/Storybook"))
        await model.perform(story, on: host)
        #expect(fake.requests.contains(.run(spaceID: Self.web, name: "Storybook", mac: false, agentID: nil)))
        #expect(model.problems[host.id] == nil)
    }

    @Test func aRefusedRunIsSaidUnderTheAppsNameAndTheNextOneClearsIt() async throws {
        let fake = Self.fake()
        let model = ClientApps()
        let host = Self.host(fake)
        await model.load(host, spaces: Self.spaces)
        let row = try #require(model.state(of: host).page?.row("acme-web/Web app"))
        fake.refusesRun = true
        await model.perform(row, on: host)
        #expect(model.problems[host.id] == "Web app: Its folder doesn’t exist.")
        #expect(model.state(of: host).page?.row("acme-web/Web app")?.run == nil)
        fake.refusesRun = false
        await model.perform(row, on: host)
        #expect(model.problems[host.id] == nil)
        #expect(!model.isBusy(row, on: host))
    }

    @Test func outputAsksForTheLastLinesOfThatApp() async throws {
        let fake = Self.fake()
        let model = ClientApps()
        let host = Self.host(fake)
        await model.load(host, spaces: Self.spaces)
        let row = try #require(model.state(of: host).page?.row("acme-web/Web app"))
        let lines = try await model.output(of: row, on: host)
        #expect(lines == ["pnpm dev", "ready on :3000", "GET / 200"])
        #expect(fake.requests.last == .output(spaceID: Self.web, name: "Web app", tail: ClientApps.outputLines))
        let own = try #require(model.state(of: host).page?.row("mac/Postgres"))
        _ = try await model.output(of: own, on: host)
        #expect(fake.requests.last == .output(spaceID: nil, name: "Postgres", tail: ClientApps.outputLines))
    }

    @Test func aSpaceItCantReadIsLeftOutAndSaidWhileTheRestShow() async throws {
        let fake = Self.fake()
        fake.unreadable = [Self.web]
        let model = ClientApps()
        let host = Self.host(fake)
        await model.load(host, spaces: Self.spaces)
        #expect(model.state(of: host).page?.groups.map(\.title) == ["On studio-mac"])
        #expect(model.problems[host.id] == "Couldn't read the apps in acme-web: That space isn't on this host.")
    }

    @Test func hiddenSpacesAreNeverAsked() async {
        let fake = Self.fake()
        let model = ClientApps()
        let host = Self.host(fake)
        await model.load(host, spaces: [Space(id: Self.web, name: "acme-web", path: "/x", hidden: true)])
        #expect(!fake.requests.contains { if case .list = $0 { true } else { false } })
    }

    @Test func offlineAndOlderHostsSayWhyAndSendNothing() async {
        let model = ClientApps()
        let fake = Self.fake()
        let offline = SettingsHost(id: UUID(), name: "Air", client: nil, capabilities: [RemoteProtocol.appsV2Capability])
        let old = Self.host(fake, capable: false)
        #expect(model.state(of: offline) == .offline)
        #expect(model.state(of: old) == .unsupported)
        await model.load(old, spaces: Self.spaces)
        #expect(fake.requests.isEmpty, "apps.v1 alone has no processes or output to ask for")
    }

    @Test func aHostThatCantAnswerFirstSaysSoAndOneThatAnsweredKeepsItsPage() async throws {
        let model = ClientApps()
        let host = Self.host(Self.fake())
        let broken = SettingsHost(id: host.id, name: host.name, client: ThrowingApps(), capabilities: host.capabilities)
        await model.load(broken, spaces: Self.spaces)
        #expect(model.state(of: broken) == .failed("The host didn't answer. Try again once it's connected."))
        await model.load(host, spaces: Self.spaces)
        #expect(model.state(of: host).page != nil)
        await model.load(broken, spaces: Self.spaces)
        #expect(model.state(of: host).page != nil, "a later failure keeps the page")
        #expect(model.problems[host.id] != nil)
    }
}

private final class ThrowingApps: SettingsClient, AppsClient, @unchecked Sendable {
    func apps(_ request: RemoteAppsRequest) async throws -> RemoteAppsResult { throw CancellationError() }
    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult { throw CancellationError() }
    func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings { HostSettings() }
    func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot { InstructionsSnapshot(directory: "~/i") }
    func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot { SuggestionsSnapshot() }
}

import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Missions and Projects run on the background host (`RuntimeHosting.headless`, as `ShepherdHost.main`
/// serves them), and the app, as its client over its local socket, draws them as This Mac's own.
/// The rules for features that act on their own hold there: every control is fenced by the revision
/// it was shown, a restart brings them back paused, Stop and Pause reach the host, and a second
/// client acts under the same fences.
@Suite("Missions and Projects on the background host", .mainActorExclusive)
@MainActor
struct LocalHostRuntimeTests {
    @MainActor
    final class Setup {
        var host: ScratchServer
        let vm: ShepherdViewModel
        let hosts: RemoteHostStore
        let space: Space
        let clientDir: URL
        let hostSettings: AppSettings
        var runtime: (missions: MissionController, coordinator: ProjectCoordinatorController, execution: ProjectExecutionController)
        let socket: String
        let tokenURL: URL

        init(host: ScratchServer, vm: ShepherdViewModel, hosts: RemoteHostStore, space: Space, clientDir: URL, hostSettings: AppSettings,
             runtime: (missions: MissionController, coordinator: ProjectCoordinatorController, execution: ProjectExecutionController),
             socket: String, tokenURL: URL) {
            self.host = host; self.vm = vm; self.hosts = hosts; self.space = space; self.clientDir = clientDir
            self.hostSettings = hostSettings; self.runtime = runtime; self.socket = socket; self.tokenURL = tokenURL
        }

        func stop() {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
            host.stop()
        }

        /// The host stops and a new one starts on the same workspace, as after a crash, a login or a drain.
        func restartHost() async throws {
            host.stop(keepFiles: true)
            host = try ScratchServer(dir: host.dir)
            runtime = LocalHostRuntimeTests.serve(host.server, settings: hostSettings)
            try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        }

        /// A paired device, over the host's TCP listener.
        func pairedClient() async throws -> RemoteHostClient {
            let tokenURL = host.dir.appendingPathComponent("paired-token")
            let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let client = RemoteHostClient()
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "Paired iPad")
            return client
        }
    }

    /// What `ShepherdHost.main` serves: threads, worktrees and the runtime, with the host's own settings.
    static func serve(_ server: SessionServer, settings: AppSettings)
        -> (missions: MissionController, coordinator: ProjectCoordinatorController, execution: ProjectExecutionController) {
        server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let worktrees = server.serveAgentQueries(WorktreeHosting(defaults: { .init(generateDescription: false) },
                                                                 deleteAgent: { id, _ in try await server.deleteAgent(id) }))
        server.setProjectsEnabled(settings.projectsEnabled)
        return RuntimeHosting.headless(server: server, settings: settings, worktrees: worktrees, mcp: { _, _, _, _, _ in nil },
                                       notify: { _, _ in }).serve()
    }

    static func setUp() async throws -> Setup {
        try StubPi.installAsEngine()
        let host = try ScratchServer()
        let hostDefaults = ScratchDefaults()
        let hostSettings = AppSettings(store: hostDefaults)
        hostSettings.projectsEnabled = true
        hostSettings.missionsEnabled = true
        let runtime = serve(host.server, settings: hostSettings)
        let repo = try makeScratchRepo(files: ["README.md": "# acme-web\n"])
        let space = Space(name: "acme-web", path: repo.path)
        try await host.server.addSpace(space)

        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let clientDir = try makeScratchDirectory("cli")
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.projectsEnabled = true
        settings.missionsEnabled = true
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(
            server: BackgroundHostClient.idleServer(directory: clientDir), ownsWorkspace: false, settings: settings,
            keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in }, restoresAgentsAtLaunch: false, checkoutReader: nil,
            hooks: HooksModel(home: clientDir.appendingPathComponent("hooks-home").path, support: clientDir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: clientDir.appendingPathComponent("apps-home").path))
        vm.connectLocalHost(socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace as the app's", timeout: .seconds(30)) {
            vm.state.spaces == host.server.state.spaces && hosts.localHost?.phase == .connected
        }
        return Setup(host: host, vm: vm, hosts: hosts, space: space, clientDir: clientDir, hostSettings: hostSettings,
                     runtime: runtime, socket: socket, tokenURL: tokenURL)
    }

    @Test func aProjectRunsOnTheHostAndIsThisMacs() async throws {
        let s = try await Self.setUp()
        defer { s.stop() }
        let model = s.vm.logicalProjects
        let id = ProjectID()
        let made = try #require(await model.create(home: .local, id: id, name: "Checkout revamp", goal: "Ship the new checkout", spaces: [s.space.id]))
        #expect(s.host.server.state.projects.map(\.id) == [id], "the host owns it")
        #expect(s.vm.server.state.projects.isEmpty, "nothing reaches the app's idle server")
        let ref = LogicalProjectRef(home: .local, id: id)
        try await eventuallyOnMain("the Project as This Mac's") { s.vm.state.projects.map(\.id) == [id] }
        #expect(s.vm.sidebarLogicalProjects.map(\.ref) == [ref] && s.vm.sidebarLogicalProjects.first?.hostName == nil,
                "This Mac's, with no host section of its own")

        // The first message starts its coordinator on the host; its thread is the app's own.
        #expect(await model.sendMessage(ref, text: "Plan the checkout work"))
        let coordinator = try #require(s.host.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator starts on the host", timeout: .seconds(30)) {
            StubPi.launches().contains { $0.argv.contains(coordinator.rawValue) }
        }
        try await eventuallyOnMain("the coordinator is the app's own thread") { s.vm.state.agents.contains { $0.id == coordinator } }
        #expect(s.vm.state.agents.first { $0.id == coordinator }?.coordinatorFor == id)
        try await eventuallyAsync("the host's coordinator conversation, read through the app") {
            guard case .snapshot(let snapshot) = try? await s.vm.nativeThread(coordinator, request: .snapshot()) else { return false }
            return !snapshot.messages.isEmpty
        }

        // Fence: an edit at the revision shown before the message is refused on the host and changes nothing.
        let shown = made.revision
        await #expect(throws: (any Error).self) {
            _ = try await s.hosts.logicalProjects(hostID: try #require(s.hosts.localHost).id,
                                                  request: .edit(projectID: id, expectedRevision: shown, name: "Stale", goal: "Stale"))
        }
        #expect(s.host.server.state.projects.first?.name == "Checkout revamp")

        // Pause from the app reaches the host.
        try await eventuallyOnMain("the app's copy is current") { s.vm.state.projects.first == s.host.server.state.projects.first }
        #expect(await model.setPaused(ref, true))
        #expect(s.host.server.state.projects.first?.pausedByPerson == true)

        // A second client sees the same Project, and its stale revision is refused too.
        let paired = try await s.pairedClient()
        defer { paired.disconnect() }
        guard case .project(let seen) = try await paired.logicalProjects(.get(projectID: id)) else { Issue.record("no Project for the paired client"); return }
        #expect(seen.paused)
        await #expect(throws: (any Error).self) {
            _ = try await paired.logicalProjects(.setPaused(projectID: id, expectedRevision: shown, paused: false))
        }
        #expect(s.host.server.state.projects.first?.paused == true)
    }

    /// A restart resumes nothing of a Project: its coordinator stays down until the person's next
    /// message, and a message being delivered is no longer in flight.
    @Test func aRestartResumesNoProjectWork() async throws {
        let s = try await Self.setUp()
        defer { s.stop() }
        let id = ProjectID()
        let ref = LogicalProjectRef(home: .local, id: id)
        _ = try #require(await s.vm.logicalProjects.create(home: .local, id: id, name: "Checkout revamp", goal: "Ship it", spaces: [s.space.id]))
        try await eventuallyOnMain("the Project as This Mac's") { s.vm.logicalProjects.project(ref) != nil }
        #expect(await s.vm.logicalProjects.sendMessage(ref, text: "Plan the checkout work"))
        let coordinator = try #require(s.host.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator starts on the host", timeout: .seconds(30)) {
            StubPi.launches().contains { $0.argv.contains(coordinator.rawValue) }
        }
        try await eventuallyOnMain("the message reaches the coordinator", timeout: .seconds(30)) {
            s.host.server.state.projects.first?.messages.first?.phase == .delivered
        }

        try await s.restartHost()
        // As `SessionHost.run` does once it serves.
        await s.host.server.respawnAgentsNeedingRecovery { AgentSpawn(agent: $0, cwd: "", settings: AgentLaunchSettings()) }
        #expect(await s.host.server.listSessions().isEmpty, "no coordinator or worker came back on its own")
        #expect(s.host.server.state.projects.first?.coordinatorAgentID == coordinator, "its conversation stays, idle")
        try await eventuallyOnMain("the app reconnects to the restarted host", timeout: .seconds(30)) {
            s.vm.state.projects.first?.revision == s.host.server.state.projects.first?.revision
        }
    }

    /// A running mission on the host: This Mac's in the sidebar and on the page, its controls fenced
    /// and run by the host's controller, paused by a restart, and the same to a paired device.
    @Test func aMissionRunsOnTheHostAndIsThisMacs() async throws {
        let s = try await Self.setUp()
        defer { s.stop() }
        let created = try await s.host.server.createMission(draft: MissionDraft(
            title: "Checkout revamp", goal: "Ship the new checkout",
            plan: MissionPlan(lanes: [MissionLane(spaceID: s.space.id, name: s.space.name)])))
        // Planning, with no job behind it: active work a restart must not resume.
        let mission = try await s.host.server.setMissionRun(id: created.id, expectedRevision: created.revision,
                                                            run: MissionRun(model: "stub/model-a", phase: .planning, activeSince: 1))
        try await eventuallyOnMain("the mission as This Mac's") { s.vm.state.missions.map(\.id) == [mission.id] }
        #expect(s.vm.sidebarMissions.map(\.id) == SidebarMission.rows([mission], selected: nil).map(\.id))
        #expect(s.vm.sidebarMissions.allSatisfy { $0.host == nil }, "no This Mac host section")

        // The page is This Mac's: the host's missions, through its connection.
        s.vm.openMission(mission.id)
        #expect(s.vm.missionsHost == nil)
        let page = try #require(s.vm.thisMacMissions as? RemoteMissionDriver)
        #expect(page.hostID == s.hosts.localHost?.id && page.selectedID == mission.id)
        try await eventuallyOnMain("the page reads the host's missions") { page.records.map(\.id) == [mission.id] }

        // Fence: an action at a revision the host no longer has is refused.
        await #expect(throws: (any Error).self) {
            try await page.perform(.launch, id: mission.id, revision: mission.revision + 7)
        }
        #expect(s.host.server.state.missions.first?.run?.phase == .planning)
        let paired = try await s.pairedClient()
        defer { paired.disconnect() }
        await #expect(throws: (any Error).self) {
            _ = try await paired.mission(.action(missionID: mission.id, revision: mission.revision + 7, action: .launch))
        }
        guard case .list(let listed) = try await paired.mission(.list) else { Issue.record("no missions for the paired client"); return }
        #expect(listed.map(\.id) == [mission.id], "a second client sees the same mission")

        // Templates are the host's, saved by its controller: a mission still planning is refused there.
        await page.loadTemplates()
        #expect(page.templates.isEmpty)
        do {
            try await page.perform(.saveTemplate("Checkout revamp", "", nil), id: mission.id,
                                   revision: try #require(page.records.first).revision)
            Issue.record("an unfinished mission was saved as a template")
        } catch let error as MissionError {
            #expect(error.code == "mission_template" && error.description.contains("once it has finished"), "\(error)")
        }

        // Pause from the app's page runs on the host.
        try await page.perform(.pause, id: mission.id, revision: try #require(page.records.first).revision)
        #expect(s.host.server.state.missions.first?.run?.phase == .paused)

        // A running mission comes back paused after the host restarts.
        let paused = try #require(s.host.server.state.missions.first)
        _ = try await s.host.server.setMissionRun(id: mission.id, expectedRevision: paused.revision,
                                                  run: MissionRun(model: "stub/model-a", phase: .planning, activeSince: 2))
        try await s.restartHost()
        #expect(s.host.server.state.missions.first?.run?.phase == .paused, "a restart never resumes a mission")
        try await eventuallyOnMain("the app reconnects and draws it paused", timeout: .seconds(30)) {
            s.vm.state.missions.first?.run?.phase == .paused
        }
    }

    /// A published mission's merge train reaches a paired device (`missions.train.v1`), and its Pause
    /// and Resume run on the host: Resume drives the train again, Pause stops the step it is on.
    @Test func aPairedDeviceSeesTheMergeTrainAndPausesAndResumesIt() async throws {
        let s = try await Self.setUp()
        defer { s.stop() }
        let lane = s.space.id
        let created = try await s.host.server.createMission(draft: MissionDraft(
            title: "Checkout funnel events", goal: "Ship checkout events",
            plan: MissionPlan(lanes: [MissionLane(spaceID: lane, name: s.space.name)])))
        var run = MissionRun(model: "stub/model-a", phase: .done)
        run.checkouts = [MissionCheckout(spaceID: lane, repo: s.space.path, path: s.space.path, branch: "mission/checkout-events",
                                         base: "refs/heads/main", head: "4b825dc", prURL: "https://github.com/acme/acme-web/pull/231")]
        // Merged, with an hour's soak left to run: the train runs no command while it soaks.
        var train = MissionTrain(order: [lane], rules: MissionTrain.Rules(between: .soak, soakMinutes: 60), startedAt: 1)
        for step in 0..<3 { train.cars[0].steps[step].status = .done }
        train.pause("Paused. The train continues from this step when you resume it.")
        run.train = train
        _ = try await s.host.server.setMissionRun(id: created.id, expectedRevision: created.revision, run: run)

        let paired = try await s.pairedClient()
        defer { paired.disconnect() }
        #expect(paired.capabilities.contains(RemoteProtocol.missionsTrainCapability))
        guard case .mission(let served, _) = try await paired.mission(.get(missionID: created.id)) else { Issue.record("no mission"); return }
        #expect(served.run?.train == train, "the host serves the train as recorded")

        // Resume from the device: the host's train runs again and starts the soak.
        guard case .done(let resumed?) = try await paired.mission(.action(missionID: created.id, revision: served.revision, action: .resumeTrain)) else {
            Issue.record("resume answered nothing"); return
        }
        #expect(resumed.run?.train?.status == .running)
        let missions = s.runtime.missions
        try await eventuallyOnMain("the host soaks the merged pull request", timeout: .seconds(30)) {
            s.host.server.state.missions.first?.run?.train?.cars[0].steps[3].status == .running && missions.trainJobs[created.id] != nil
        }

        // Pause from the device, against whatever revision it last saw: the step stops and nothing drives the train.
        guard case .done(let paused?) = try await paired.mission(.action(missionID: created.id, revision: resumed.revision, action: .pauseTrain)) else {
            Issue.record("pause answered nothing"); return
        }
        #expect(paused.run?.train?.status == .paused)
        try await eventuallyOnMain("the train job ends") { missions.trainJobs[created.id] == nil }
        let after = try #require(s.host.server.state.missions.first?.run?.train)
        #expect(after.status == .paused && after.cars[0].steps[3].status == .pending && after.merged == 1)
    }

    /// New mission from the app's page creates and plans it on the host.
    @Test func newMissionFromTheAppIsCreatedOnTheHost() async throws {
        let s = try await Self.setUp()
        defer { s.stop() }
        s.vm.openNewMission()
        let page = try #require(s.vm.thisMacMissions as? RemoteMissionDriver)
        #expect(page.startRequested)
        await page.refreshModels()
        #expect(page.availableSpaces.map(\.id) == [s.space.id])
        let model = try #require(page.defaultModel ?? page.availableModels.first)
        let branch = try #require(page.defaultBranches[s.space.id] ?? page.branchChoices[s.space.id]?.first)
        let id = try await page.create(goal: "Ship the new checkout", spaces: [s.space.id], model: model, branches: [s.space.id: branch])
        #expect(s.host.server.state.missions.map(\.id) == [id])
        #expect(s.vm.server.state.missions.isEmpty)
        try await eventuallyOnMain("the new mission as This Mac's") { s.vm.state.missions.map(\.id) == [id] }
        try await eventuallyOnMain("its planning stops") { s.host.server.state.missions.first?.run?.phase.active == false || s.runtime.missions.jobs[id] == nil }
    }
}

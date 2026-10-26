import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import TerminalSurfaceKit

/// A new agent's thread while its pi boots, through the real view model and the stub pi on
/// PATH (launched the way the app launches pi). The stub holds its startup until the test
/// creates its gate file, so the window a slow pi leaves is as wide as the test needs.
@Suite("Agent startup", .mainActorExclusive)
@MainActor
struct AgentStartupTests {
    private static let gate = "release-pi"

    /// Makes every stub pi started in `dir` from now on wait for the gate (then exit with
    /// `exit`, when given) before it reads anything.
    private static func holdPi(in dir: URL, exit: Int? = nil) throws {
        let config: [String: Any] = exit.map { ["gate": gate, "exit": $0] } ?? ["gate": gate]
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("stub-pi-startup.json"))
    }

    private static func releasePi(in dir: URL) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(gate).path, contents: nil)
    }

    /// ⌘N's agent, started in the background (⌘N itself would focus the window).
    private func quickCreate(_ vm: ShepherdViewModel, in space: Space, app: AppHarness) -> Task<AgentID, Error> {
        let config = ShepherdViewModel.quickAgentConfig(for: space, defaults: app.settings.agentDefaults)
        return Task { try await vm.startAgent(config, selectAfter: false) }
    }

    @Test(arguments: [(false, true), (true, true), (false, false), (true, false)])
    func worktreeCreationAndRestoreUseHostMCPSettingsAndOwningSpace(restoring: Bool, mcpEnabled: Bool) async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.piMCPExtension = mcpEnabled
        app.settings.mcpProjectConfig = false
        let owner = app.dir.appendingPathComponent("owner")
        let checkout = app.dir.appendingPathComponent("owner-worktree")
        for folder in [owner, checkout] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let space = Fixture.space(path: owner.path)
        let vm: ShepherdViewModel
        if restoring {
            var fixture = Fixture.agent(in: space, cwd: checkout.path)
            fixture.agent.worktreeBranch = "fix/task"
            fixture.agent.worktreePath = checkout.path
            vm = try await app.start(with: ShepherdState(spaces: [space], tabs: [fixture.tab], agents: [fixture.agent]),
                                     restoringAgents: true)
        } else {
            vm = try await app.start(with: ShepherdState(spaces: [space]))
            var config = ShepherdViewModel.quickAgentConfig(for: space)
            config.workingDirectory = checkout.path
            config.worktreeBranch = "fix/task"
            config.worktreePath = checkout.path
            _ = try await vm.startAgent(config, selectAfter: false, focusWindow: false)
        }
        try await eventuallyOnMain("the owned checkout to launch") {
            StubPi.launches().contains { PiHome.canonical($0.cwd) == PiHome.canonical(checkout.path) }
        }
        let launch = try #require(StubPi.launches().last { PiHome.canonical($0.cwd) == PiHome.canonical(checkout.path) })
        #expect(launch.env["SHEPHERD_MCP_OWNING_SPACE"] == (mcpEnabled ? PiHome.canonical(owner.path) : nil))
        #expect(launch.env["SHEPHERD_MCP_WORKTREE_CWD"] == (mcpEnabled ? PiHome.canonical(checkout.path) : nil))
        #expect(launch.env["SHEPHERD_RESOURCE_OWNING_SPACE"] == PiHome.canonical(owner.path))
        #expect(launch.env["SHEPHERD_RESOURCE_WORKTREE_CWD"] == PiHome.canonical(checkout.path))
        #expect(!launch.argv.contains("--approve"))
        #expect(launch.env["SHEPHERD_EXT_MCP_PROJECT"] == nil, "Shared .mcp.json keeps its independent opt-in")
        #expect(vm.state.agents.first?.spaceID == space.id)
    }

    @Test(arguments: [false, true])
    func threadsWithoutWorktreeMetadataInheritOnlyFromTheirOwnersRegisteredGitCheckout(unrelated: Bool) async throws {
        try StubPi.installAsEngine()
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let registered = try GitWorktree.add(repo: sandbox.repo.path, branch: "agent/registered")
        let checkout: String
        if unrelated {
            let folder = sandbox.root.appendingPathComponent("unrelated")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A forged pointer to the same Git common directory is not ownership.
            let pointer = try Data(contentsOf: URL(fileURLWithPath: registered).appendingPathComponent(".git"))
            try pointer.write(to: folder.appendingPathComponent(".git"))
            checkout = folder.path
        } else {
            checkout = registered
        }
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.piMCPExtension = true
        let space = Fixture.space(path: sandbox.repo.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        var config = ShepherdViewModel.quickAgentConfig(for: space)
        config.workingDirectory = checkout
        _ = try await vm.startAgent(config, selectAfter: false, focusWindow: false)
        try await eventuallyOnMain("the checkout to launch") {
            StubPi.launches().contains { PiHome.canonical($0.cwd) == PiHome.canonical(checkout) }
        }
        let launch = try #require(StubPi.launches().last { PiHome.canonical($0.cwd) == PiHome.canonical(checkout) })
        #expect(launch.env["SHEPHERD_MCP_OWNING_SPACE"] == (unrelated ? nil : PiHome.canonical(sandbox.repo.path)))
        #expect(launch.env["SHEPHERD_RESOURCE_OWNING_SPACE"] == (unrelated ? nil : PiHome.canonical(sandbox.repo.path)))
        #expect(launch.env["SHEPHERD_RESOURCE_WORKTREE_CWD"] == (unrelated ? nil : PiHome.canonical(checkout)))
        #expect(vm.state.agents.first?.worktreePath == nil, "MCP inheritance does not grant worktree-management metadata")
    }

    @Test func aNewAgentsThreadShowsStartingWithoutAnErrorAndSendsOnceReady() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))

        let creating = quickCreate(vm, in: space, app: app)
        // The thread polls from the moment the agent appears, as its view does: before its pi
        // is even bound to the pane.
        try await eventuallyOnMain("the new agent to appear") { vm.state.agents.count == 1 }
        let id = try #require(vm.state.agents.first?.id)
        let store = vm.threadStores.store(for: id)
        let recorder = ThreadRecorder(store)
        let server = app.server
        let polling = Task { await store.run(request: recorder.forward { try await server.nativeThread(agentID: id, request: $0) }) }
        defer { polling.cancel(); store.stop() }

        try await eventuallyOnMain("the thread to show pi starting") { store.starting }
        #expect(store.loadError == nil && !store.ready)
        #expect(vm.sidebarLists.working.isEmpty)
        #expect(vm.sidebarLists.recents.map(\.id) == [.local(id)], "an empty thread is not working")
        #expect(store.pollInterval == .milliseconds(200))
        #expect(try await creating.value == id)
        // Known to be empty from the start: the new agent's thread draws before pi answers.
        #expect(store.previewing && store.messages.isEmpty && store.snapshot?.thinking == app.settings.agentDefaults.thinking.rawValue)

        store.draft = "hello while starting"
        #expect(store.acceptsSend)
        let sending = Task { await store.send() }
        try await eventuallyOnMain("the send to wait for pi") { store.busy }
        #expect(store.draft == "hello while starting" && store.sentCount == 0)

        Self.releasePi(in: app.dir)
        await sending.value

        #expect(store.sentCount == 1 && store.draft.isEmpty && store.notice == nil)
        // A pushed refresh may supersede the send's own refresh. Acceptance is already
        // known, but readiness belongs to the latest pull rather than the send Task's return.
        try await eventuallyOnMain("the latest pull to show the ready thread") {
            store.ready && !store.starting && store.loadError == nil
        }
        try await eventuallyAsync("pi to receive the message sent while it started", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "hello while starting" } }
        }
        #expect(recorder.errorsShown.isEmpty, "no poll ever found the thread showing an error")
        #expect(recorder.answers.contains(NativeThreadCode.starting))
        #expect(!recorder.answers.contains(NativeThreadCode.unavailable))
        let firstSnapshot = try #require(recorder.answers.firstIndex(of: "snapshot"))
        let send = try #require(recorder.requests.firstIndex { if case .send = $0 { true } else { false } })
        #expect(send > firstSnapshot, "nothing is dispatched before pi serves the thread")
    }

    /// What the user asked for shows the moment the agent appears, while its pi is held, and it
    /// stays one row, the same row, when the host's first snapshot carries it and when pi starts it.
    @Test func aNewAgentsOpeningPromptShowsWhilePiStartsAndStaysOneRow() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))

        let prompt = "tools:0 fix the build"
        var config = ShepherdViewModel.quickAgentConfig(for: space, defaults: app.settings.agentDefaults)
        config.initialPrompt = prompt
        let creating = Task { try await vm.startAgent(config, selectAfter: false) }
        try await eventuallyOnMain("the new agent to appear") { vm.state.agents.count == 1 }
        let id = try #require(vm.state.agents.first?.id)
        let store = vm.threadStores.store(for: id)
        /// The prompt's row, once per copy of it the thread draws.
        func promptRows() -> [NativeThreadRow] {
            store.rows.filter(\.isUser).flatMap { row in
                row.turn.messages.filter { $0.blocks.first?.text == prompt }.map { _ in row }
            }
        }

        #expect(store.previewing && !store.ready)
        #expect(vm.sidebarLists.recents.isEmpty)
        let startingRow = try #require(vm.sidebarLists.working.first)
        #expect(startingRow.id == .local(id) && startingRow.leading == .dot(.running))
        #expect(startingRow.accessibilityLabel.hasSuffix(", running"))
        let shown = try #require(promptRows().first, "the prompt shows while pi starts")
        #expect(promptRows().count == 1 && store.rows.count == 1)

        let recorder = ThreadRecorder(store)
        let server = app.server
        let polling = Task { await store.run(request: recorder.forward { try await server.nativeThread(agentID: id, request: $0) }) }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to show pi starting") { store.starting }
        #expect(try await creating.value == id)
        #expect(promptRows().map(\.id) == [shown.id], "the prompt still shows while pi is starting")
        let reporter = try ExtensionClient(path: app.scratch.socketPath)
        try reporter.send(.setAgentStatus(agentID: id, status: .idle))
        try await eventuallyOnMain("the startup idle report to arrive") { vm.statusSince[id] != nil }
        #expect(vm.sidebarLists.working.map(\.id) == [.local(id)], "startup idle must not move the pending prompt")
        try reporter.send(.setAgentStatus(agentID: id, status: .working))
        try await eventuallyOnMain("the first turn to replace the startup marker") {
            vm.state.agents.first?.status == .working && !vm.sidebarOpeningTurns.contains(id)
        }
        #expect(vm.sidebarLists.working.map(\.id) == [.local(id)])

        Self.releasePi(in: app.dir)
        var most = 0
        try await eventuallyOnMain("pi to answer the opening prompt", timeout: .seconds(20)) {
            most = max(most, promptRows().count)
            return store.ready && store.displayedMessages.contains { $0.role == "assistant" && $0.blocks.contains { $0.text == "Reply to \(prompt)" } }
        }
        #expect(most == 1, "the prompt never showed twice")
        #expect(promptRows().map(\.id) == [shown.id], "the row kept its identity from preview to pi's message")
        let landed = store.displayedMessages.filter { $0.role == "user" && $0.blocks.first?.text == prompt }
        #expect(landed.count == 1 && landed.first?.status != "pending", "pi's own message, once")
        try reporter.send(.setAgentStatus(agentID: id, status: .done))
        try await eventuallyOnMain("the completed opening turn to enter Done") {
            vm.sidebarLists.done.map(\.id) == [.local(id)]
        }
    }

    @Test func anOpeningCommandThatStartsNoTurnReturnsToRecents() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        var config = ShepherdViewModel.quickAgentConfig(for: space, defaults: app.settings.agentDefaults)
        config.initialPrompt = "/session-name report Opening command finished"
        let id = try await vm.startAgent(config, selectAfter: false)
        #expect(vm.sidebarLists.working.map(\.id) == [.local(id)])
        Self.releasePi(in: app.dir)
        let server = app.server
        try await eventuallyAsync("the opening command to run without starting a turn") {
            guard case .snapshot(let snapshot) = try await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.blocks.contains { $0.text == "Opening command finished" } }
        }
        try await eventuallyOnMain("the command-only opening to leave Working without a mounted thread") {
            vm.sidebarLists.recents.map(\.id) == [.local(id)] && vm.sidebarOpeningTurns.isEmpty
        }
        #expect(vm.state.agents.first?.status == .idle)
    }

    /// A relaunch: every restored pane still names the previous run's pi, and every agent's pi
    /// respawns (a few at a time, `AgentStartQueue`). Each thread starts quietly, a thread switched
    /// away from and back to meanwhile starts again, and all come up with their history.
    @Test func restoredAgentsStartQuietlyAfterARelaunch() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<3).map { Fixture.agent("worker \($0)", in: space, order: $0, piSession: SessionID()) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let server = app.server

        let stores = agents.map { vm.threadStores.store(for: $0.agent.id) }
        let recorders = stores.map(ThreadRecorder.init)
        func poll(_ index: Int) -> Task<Void, Never> {
            let id = agents[index].agent.id
            return Task { await stores[index].run(request: recorders[index].forward { try await server.nativeThread(agentID: id, request: $0) }) }
        }
        var polls = agents.indices.map(poll)
        defer { polls.forEach { $0.cancel() } }
        try await eventuallyOnMain("every restored thread to show pi starting, before its pi respawns") { stores.allSatisfy(\.starting) }

        let panes = agents.map { vm.sessions.session(for: $0.piPane, in: $0.tab) }
        try await eventuallyOnMain("every restored pane to bind its new pi") { panes.allSatisfy { $0.phase == .live } }
        try await eventuallyOnMain("every thread to poll its new pi") { stores.allSatisfy(\.starting) }

        // Switching away stops a thread; switching back polls it again.
        polls[0].cancel()
        stores[0].stop()
        #expect(!stores[0].starting && stores[0].loadError == nil)
        polls[0] = poll(0)
        try await eventuallyOnMain("the thread switched back to to show pi starting") { stores[0].starting }

        Self.releasePi(in: app.dir)
        try await eventuallyOnMain("every restored thread to come up", timeout: .seconds(20)) { stores.allSatisfy(\.ready) }
        for (store, recorder) in zip(stores, recorders) {
            #expect(!store.starting && store.loadError == nil && !store.messages.isEmpty)
            #expect(recorder.errorsShown.isEmpty, "no poll ever found the thread showing an error")
            #expect(!recorder.answers.contains(NativeThreadCode.unavailable))
        }
    }

    /// Mounting hidden layouts is not demand. Selection starts only that agent and its terminals.
    @Test func settledRestoredAgentsStayDormantUntilSelectedOrDemanded() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<112).map { Fixture.agent("worker \($0)", in: space, order: $0, auxiliary: 1, piSession: SessionID()) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents), restoringAgents: true)
        let server = app.server
        let onScreen = try #require(vm.selectedAgentID)
        /// The agents whose pane is bound to a live pi.
        func started() async -> Set<AgentID> {
            let alive = Set(await server.listSessions().filter(\.isAlive).map(\.id))
            let state = server.state
            return Set(state.agents.filter { agent in
                guard let paneID = agent.paneID, let tab = state.tabs.first(where: { $0.id == agent.tabID }),
                      let session = tab.layout.leaf(withID: paneID)?.sessionID else { return false }
                return alive.contains(session)
            }.map(\.id))
        }

        try await eventuallyAsync("the agent on screen to start") { await started().contains(onScreen) }
        // Exercise precisely what the native hidden layout deck does, including utility panes.
        for agent in agents where agent.agent.id != onScreen {
            for pane in agent.tab.layout.leaves { _ = vm.sessions.session(for: pane, in: agent.tab) }
        }
        #expect(vm.sessions.startQueue.waiting.isEmpty)
        #expect(await started() == [onScreen], "settled hidden threads are not queued")
        let selected = try #require(agents.last?.agent.id)
        vm.selectAgent(selected)
        try await eventuallyAsync("the agent selected meanwhile to start at once") { await started().contains(selected) }
        #expect(await started() == [onScreen, selected])

        Self.releasePi(in: app.dir)

        try await eventuallyOnMain("selected threads to finish booting") { vm.sessions.startQueue.ahead.isEmpty }
        #expect(await started() == [onScreen, selected])
        #expect(vm.sessions.startQueue.waiting.isEmpty)

        let demanded = agents[1].agent.id
        _ = try? await server.nativeThread(agentID: demanded, request: .snapshot())
        try await eventuallyAsync("remote/native demand to start only its thread") { await started().contains(demanded) }
        #expect(await started() == [onScreen, selected, demanded])
        #expect(vm.sessions.liveSession(forPane: agents[1].auxiliary[0].id) == nil)
        // An explicit design/worktree launch remains a start, even without selection.
        let explicit = agents[2].agent.id
        vm.sessions.startRestoredAgents([explicit], first: [], in: vm.state)
        try await eventuallyAsync("explicit restore to start") { await started().contains(explicit) }
        #expect(await started() == [onScreen, selected, demanded, explicit])
    }

    @Test(arguments: [false, true])
    func hiddenMountedThreadsDoNotDemandTheirDormantProcesses(dark: Bool) async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<4).map { Fixture.agent("worker \($0)", in: space, order: $0, auxiliary: 1, piSession: SessionID()) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents), restoringAgents: true)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: dark, WorkspaceView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("all hidden native layouts to mount") { vm.mountedTabs.count == agents.count }
        let selected = try #require(vm.selectedAgentID)
        try await eventuallyOnMain("the visible native thread to serve") { vm.threadStores.store(for: selected).ready }
        #expect(vm.sessions.startQueue.started == [selected])
        #expect(vm.sessions.startQueue.waiting.isEmpty)
        vm.sessions.updateAppearance(ThemeManager.shared.current.terminal)
        vm.sessions.updateSurfaceConfiguration()
        for agent in agents where agent.agent.id != selected {
            #expect(vm.sessions.liveSession(forPane: agent.piPane.id) == nil)
            #expect(vm.sessions.liveSession(forPane: agent.auxiliary[0].id) == nil)
            let pane = vm.sessions.session(for: agent.auxiliary[0], in: agent.tab)
            #expect(pane.isDormant && !pane.hasTerminalModel, "hidden restored terminals allocate no model or Ghostty surface")
        }
        let hidden = try #require(agents.first { $0.agent.id != selected })
        let mounted = vm.mountedTabs.map(\.id)
        vm.selectAgent(hidden.agent.id)
        try await eventuallyOnMain("the selected dormant native thread to serve") { vm.threadStores.store(for: hidden.agent.id).ready }
        #expect(vm.mountedTabs.map(\.id) == mounted, "selection is still a visibility flip")
        #expect(vm.sessions.startQueue.started == [selected, hidden.agent.id])
        let terminal = vm.sessions.session(for: hidden.auxiliary[0], in: hidden.tab)
        try await eventuallyOnMain("the activated terminal to bind") { terminal.phase == .live }
        #expect(!terminal.isDormant && terminal.hasTerminalModel)
        vm.sessions.updateAppearance((dark ? ShepherdTheme.shepherdDesignDark : ShepherdTheme.shepherdDesignLight).terminal)
        vm.terminalPanels.update(.init(host: nil, tab: hidden.tab.id)) { $0.shown = true }
        try await eventuallyOnMain("the terminal surface to mount") {
            window.layout()
            return TerminalFirstResponder.view(ownedBy: terminal.terminal.model.viewState, in: window.window) != nil
        }
        let surface = try #require(TerminalFirstResponder.view(ownedBy: terminal.terminal.model.viewState, in: window.window))
        vm.selectAgent(selected)
        try await eventuallyOnMain("the first thread to be visible again") { vm.threadStores.store(for: selected).isLive }
        vm.selectAgent(hidden.agent.id)
        try await eventuallyOnMain("the activated thread and its real history to be visible again") {
            let store = vm.threadStores.store(for: hidden.agent.id)
            return store.isLive && !store.messages.isEmpty
        }
        window.layout()
        #expect(TerminalFirstResponder.view(ownedBy: terminal.terminal.model.viewState, in: window.window) === surface)
        if let directory = ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"] {
            let bitmap = try #require(window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds))
            window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("restored-terminal-\(dark ? "dark" : "light").png"))
        }
    }

    @Test(arguments: [false, true])
    func fallbackSelectionActivatesRestoredTerminals(deletingSpace: Bool) async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let other = app.dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let firstSpace = Fixture.space("first", path: app.dir.path)
        let nextSpace = Fixture.space("next", path: other.path)
        var first = Fixture.agent("first", in: firstSpace, auxiliary: 1)
        first.agent.lastActiveAt = 20
        var next = Fixture.agent("next", in: deletingSpace ? nextSpace : firstSpace, auxiliary: 1)
        next.agent.lastActiveAt = 10
        let vm = try await app.start(with: Fixture.state(spaces: [firstSpace, nextSpace], agents: [first, next]), restoringAgents: true)
        #expect(vm.selectedAgentID == first.agent.id)
        let terminal = vm.sessions.session(for: next.auxiliary[0], in: next.tab)
        #expect(terminal.isDormant && !terminal.hasTerminalModel)
        if deletingSpace { vm.deleteSpace(firstSpace.id) }
        else { try await app.server.deleteAgent(first.agent.id) }
        try await eventuallyOnMain("fallback selection and its terminal process to start") {
            vm.selectedAgentID == next.agent.id && vm.sessions.liveSession(forPane: next.auxiliary[0].id) != nil
        }
        #expect(!terminal.isDormant && terminal.hasTerminalModel)
    }

    @Test func unfinishedOrdinaryWorkAndItsQueueStartWithoutSelection() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var selected = Fixture.agent("selected", in: space, order: 0)
        selected.agent.lastActiveAt = 10
        var recovering = Fixture.agent("recovering", in: space, order: 1, auxiliary: 1)
        recovering.agent.piSessionID = "stub-session"
        let saved = AgentRecoveryStore.Checkpoint(sessionID: "stub-session", active: true,
            items: [.init(entry: NativeQueuedMessage(id: UUID(), text: "recovered queued input", sentAt: 1), images: [])],
            pending: [], paused: false, mode: .oneAtATime)
        try AgentRecoveryStore(directory: app.dir.appendingPathComponent("agent-recovery")).save(saved, for: recovering.agent.id)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [selected, recovering]), restoringAgents: true)
        #expect(vm.selectedAgentID == selected.agent.id)
        // Observe binding, not native snapshots: the latter are explicit demand themselves.
        try await eventuallyOnMain("durable unfinished work to start without demand") {
            vm.sessions.liveSession(forPane: recovering.piPane.id) != nil
        }
        try await eventuallyAsync("the recovered queue to finish") {
            guard case .snapshot(let snapshot) = try await app.server.nativeThread(agentID: recovering.agent.id, request: .snapshot()) else { return false }
            return !snapshot.running && snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "recovered queued input" } }
        }
        #expect(vm.sessions.liveSession(forPane: recovering.auxiliary[0].id) == nil)
        #expect(vm.selectedAgentID == selected.agent.id)
    }

    /// A new agent's pi is its creation's to spawn: it never waits in the launch queue behind the
    /// restored agents still waiting their turn.
    @Test func aNewAgentsPiStartsAtOnceWhileRestoredAgentsWaitTheirTurn() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<4).map { Fixture.agent("worker \($0)", in: space, order: $0, piSession: SessionID()) }
        let launched = ContinuousClock.now
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents), restoringAgents: true)
        let server = app.server
        let onScreen = try #require(vm.selectedAgentID)
        /// The agents whose pane is bound to a live pi.
        func started() async -> Set<AgentID> {
            let alive = Set(await server.listSessions().filter(\.isAlive).map(\.id))
            let state = server.state
            return Set(state.agents.filter { agent in
                guard let paneID = agent.paneID, let tab = state.tabs.first(where: { $0.id == agent.tabID }),
                      let session = tab.layout.leaf(withID: paneID)?.sessionID else { return false }
                return alive.contains(session)
            }.map(\.id))
        }
        try await eventuallyAsync("the agent on screen to start") { await started().contains(onScreen) }

        let created = try await quickCreate(vm, in: space, app: app).value

        #expect(await started().contains(created), "the new agent started")
        #expect(!vm.sessions.startQueue.started.contains(created), "it never entered the launch queue")
        // The restored ones wait while the agent on screen holds the queue, which it does for at
        // most `aheadHold` from launch; a slower creation proves nothing about them.
        if ContinuousClock.now - launched < AgentStartQueue.aheadHold {
            #expect(await started() == [onScreen, created], "the restored ones still wait")
        }
        Self.releasePi(in: app.dir)
        try await eventuallyOnMain("the selected thread to serve") { vm.sessions.startQueue.ahead.isEmpty }
        #expect(await started() == [onScreen, created])
        #expect(vm.sessions.startQueue.waiting.isEmpty)
    }

    /// The agent on screen at launch whose pi exits while it boots stops holding the queue at
    /// once: the others start then, not when its hold (`AgentStartQueue.aheadHold`) runs out.
    @Test func anAgentOnScreenWhosePiExitsAtLaunchLetsTheOthersStartAtOnce() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let broken = app.dir.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        // Its pi exits only once the test has seen it on screen.
        try Self.holdPi(in: broken, exit: 1)
        let space = Fixture.space(path: app.dir.path)
        var agents = [Fixture.agent("broken", in: space, order: 0, cwd: broken.path, piSession: SessionID())]
            + (1..<4).map { Fixture.agent("worker \($0)", in: space, order: $0, piSession: SessionID()) }
        // The broken one is the most recently active, so it is the one on screen at launch.
        agents[0].agent.lastActiveAt = 10
        let brokenID = agents[0].agent.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents), restoringAgents: true)
        #expect(vm.selectedAgentID == brokenID)
        let server = app.server
        let others = Set(agents.dropFirst().map(\.agent.id))
        // Explicit background starts still use the bounded queue (as recovery starts do).
        vm.sessions.startRestoredAgents(agents.dropFirst().map(\.agent.id), first: [], in: vm.state)

        Self.releasePi(in: broken)
        try await eventuallyOnMain("the broken agent's pi to exit, keeping the agent") { vm.cannotStart.contains(brokenID) }
        #expect(vm.state.agents.contains { $0.id == brokenID })
        let exited = ContinuousClock.now
        try await eventuallyAsync("the others to start") {
            let alive = Set(await server.listSessions().filter(\.isAlive).map(\.id))
            let state = server.state
            return others.allSatisfy { id in
                guard let agent = state.agents.first(where: { $0.id == id }), let paneID = agent.paneID,
                      let tab = state.tabs.first(where: { $0.id == agent.tabID }),
                      let session = tab.layout.leaf(withID: paneID)?.sessionID else { return false }
                return alive.contains(session)
            }
        }
        #expect(ContinuousClock.now - exited < AgentStartQueue.aheadHold / 2, "the queue waited on a pi that had exited")
    }

    /// Only an agent's first start waits in the launch queue: a pane session made again once it
    /// has started (a view detached and remounted) binds at once.
    @Test func aPaneSessionMadeAgainAfterItsAgentStartedBindsAtOnce() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("worker", in: space, piSession: SessionID())
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), restoringAgents: true)
        let first = vm.sessions.session(for: agent.piPane, in: agent.tab)
        try await eventuallyOnMain("the restored agent's pi to bind") { first.phase == .live }

        vm.sessions.detachPane(agent.piPane.id)
        let again = vm.sessions.session(for: agent.piPane, in: agent.tab)

        #expect(again !== first)
        try await eventuallyOnMain("the pane made again to bind the same pi") { again.phase == .live }
        #expect(again.sessionID == first.sessionID)
    }

    /// A thread on screen comes up the moment the server says its pi serves: this store never
    /// polls on its own, so only that signal can bring it up.
    @Test func aThreadComesUpTheMomentItsPiServesWithoutWaitingForAPoll() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("worker", in: space, piSession: SessionID())
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = NativeThreadStore { duration in
            // Only the spacing between pushed pulls ever ends: the poll interval never does.
            guard duration > NativeThreadStore.pushedPullSpacing else { return }
            let (cancelled, continuation) = AsyncStream<Void>.makeStream()
            for await _ in cancelled {}
            continuation.finish()
            throw CancellationError()
        }
        vm.threadStores.install(store, for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to show pi starting") { store.starting }
        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)
        try await eventuallyOnMain("the pane to bind its pi") { pane.phase == .live }

        Self.releasePi(in: app.dir)

        try await eventuallyOnMain("the thread to come up", timeout: .seconds(20)) { store.ready }
        #expect(!store.starting && store.loadError == nil && !store.messages.isEmpty)
    }

    /// The stub pi's history, as pi would have written it into the agent's session file.
    private static func writeStubHistory(sessionID: String, cwd: String, sessionsRoot: URL) throws {
        let directory = PiSessionFile.projectDirectory(forCwd: cwd, sessionsRoot: sessionsRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"2026-09-24T00:00:00.000Z","cwd":"\#(PiSessionFile.realPath(cwd))"}"#,
            #"{"type":"message","id":"e0","parentId":null,"timestamp":"2026-09-24T00:00:01.000Z","message":{"role":"user","content":"Hello!","timestamp":1733234567890}}"#,
            #"{"type":"message","id":"e1","parentId":"e0","timestamp":"2026-09-24T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hello! How can I help?"}],"provider":"anthropic","model":"claude-sonnet-4-20250514","stopReason":"stop","timestamp":1733234567891}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("2026-09-24T00-00-00-000Z_\(sessionID).jsonl"))
    }

    /// A relaunched agent's thread shows its history from pi's session file while pi boots,
    /// not live, and pi's first snapshot then lands on the same rows: the thread never empties.
    @Test func aRestoredThreadShowsItsHistoryFromDiskUntilPiServesTheSameRows() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir)
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("worker", in: space, piSession: SessionID())
        try Self.writeStubHistory(sessionID: agent.agent.effectivePiSessionID, cwd: space.path, sessionsRoot: app.server.pi.sessionsRoot)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let preview = PiSessionFile.previewLoader(sessionID: agent.agent.effectivePiSessionID, cwd: space.path,
                                                  sessionsRoot: app.server.pi.sessionsRoot)
        let polling = Task { await store.run(request: { try await server.nativeThread(agentID: id, request: $0) }, preview: preview) }
        defer { polling.cancel(); store.stop() }

        try await eventuallyOnMain("the thread to show its history from disk") { store.previewing && !store.rows.isEmpty }
        #expect(!store.ready && !store.supports("send") && store.loadError == nil)
        #expect(store.snapshot?.model == "anthropic/claude-sonnet-4-20250514")
        let fromDisk = store.rows.map(\.id)
        @MainActor final class Shown { var rows: [[String]] = [] }
        let shown = Shown()
        let watching = Task { @MainActor in
            while !Task.isCancelled {
                shown.rows.append(store.rows.map(\.id))
                await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = store.rows } onChange: { Task { @MainActor in changed.resume() } }
                }
            }
        }
        defer { watching.cancel() }
        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)
        try await eventuallyOnMain("the pane to bind its pi") { pane.phase == .live }

        Self.releasePi(in: app.dir)

        try await eventuallyOnMain("pi's snapshot to replace the disk's", timeout: .seconds(20)) { store.ready }
        #expect(!store.previewing && store.rows.map(\.id) == fromDisk)
        #expect(store.messages.map(\.entryID) == ["user:1733234567890", "assistant:1733234567891"])
        #expect(shown.rows.allSatisfy { $0 == fromDisk }, "the rows never changed on the way: \(shown.rows)")
    }

    /// pi not installed, or a broken config: the launch ends in the reason, with the agent kept
    /// (AgentStartProblemTests has every cause), never an endless start.
    @Test func aPiThatExitsWhileStartingEndsInItsReasonNotAnEndlessStart() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.holdPi(in: app.dir, exit: 127)
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))

        let creating = quickCreate(vm, in: space, app: app)
        try await eventuallyOnMain("the new agent to appear") { vm.state.agents.count == 1 }
        let agent = try #require(vm.state.agents.first)
        let tab = try #require(vm.state.tabs.first { $0.id == agent.tabID })
        let leaf = try #require(agent.paneID.flatMap { tab.layout.leaf(withID: $0) })
        let pane = vm.sessions.session(for: leaf, in: tab)
        let store = vm.threadStores.store(for: agent.id)
        let server = app.server, id = agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to show pi starting") { store.starting }
        _ = try await creating.value

        Self.releasePi(in: app.dir)

        try await eventuallyOnMain("the pane to show pi stopped", timeout: .seconds(20)) { pane.phase == .stopped }
        try await eventuallyOnMain("the thread to say why") { store.startProblem?.kind == .engineMissing }
        #expect(!store.starting && store.loadError == nil)
        #expect(store.startProblem?.exitCode == 127)
        #expect(server.state.agents.map(\.id) == [id] && vm.state.agents.map(\.id) == [id])
    }

    /// Only a pi that was serving and went away is a lost connection.
    @Test func aLiveThreadWhosePiDiesShowsTheLostConnection() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }

        await store.send(text: "die")

        try await eventuallyAsync("the lost connection to show", timeout: .seconds(20)) {
            await store.refresh()
            return store.loadError != nil
        }
        #expect(!store.starting)
    }

    /// A remote client watching a host's agent start sees the same quiet start, and its send
    /// waits for the host's pi.
    @Test func aRemoteAgentStartingOnItsHostIsStartingOnTheClient() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        try Self.holdPi(in: remote.host.dir)
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = try await remote.host.liveAgent(in: space)
        try await remote.host.server.putState(Fixture.state(spaces: [space], agents: [agent]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        let store = vm.remoteThreadStores.store(for: ref)
        let hosts = local.remoteHosts
        let polling = Task { await store.run { try await hosts.nativeThread(ref, request: $0) } }
        defer { polling.cancel(); store.stop() }

        try await eventuallyOnMain("the remote thread to show pi starting") { store.starting }
        #expect(store.loadError == nil && !store.ready)
        store.draft = "hello from the client"
        let sending = Task { await store.send() }
        try await eventuallyOnMain("the send to wait for the host's pi") { store.busy }

        Self.releasePi(in: remote.host.dir)
        await sending.value

        #expect(store.sentCount == 1 && store.draft.isEmpty && store.loadError == nil)
        let host = remote.host.server, id = agent.agent.id
        try await eventuallyAsync("the host's pi to receive the message", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await host.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "hello from the client" } }
        }
    }
}

/// Stands between a thread store and its host: records every request, every answer (the
/// failure code, or the result's kind), and whether the store showed an error when it polled
/// (which is the state its previous answer left).
@MainActor
final class ThreadRecorder {
    private weak var store: NativeThreadStore?
    private(set) var requests: [NativeThreadRequest] = []
    private(set) var answers: [String] = []
    private(set) var errorsShown: [String] = []

    init(_ store: NativeThreadStore) { self.store = store }

    func forward(_ request: @escaping NativeThreadStore.Request) -> NativeThreadStore.Request {
        { [self] value in
            if let error = store?.loadError { errorsShown.append(error) }
            requests.append(value)
            do {
                let result = try await request(value)
                switch result {
                case .failure(let code, _): answers.append(code)
                case .snapshot: answers.append("snapshot")
                case .unchanged: answers.append("unchanged")
                case .accepted: answers.append("accepted")
                case .transcript: answers.append("transcript")
                case .imageChunk: answers.append("imageChunk")
                case .artifactChunk: answers.append("artifactChunk")
                }
                return result
            } catch {
                if case RemoteHostClientError.rejected(let code, _) = error { answers.append(code) } else { answers.append("\(error)") }
                throw error
            }
        }
    }
}

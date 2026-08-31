import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
@testable import ShepherdApp

@Suite("Shepherd view model", .serialized)
@MainActor
struct ShepherdViewModelTests {
    private struct Fixture {
        let dir: URL
        let server: SessionServer

        init() throws {
            dir = URL(fileURLWithPath: "/tmp/shepherd-vm-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            server = SessionServer(
                socketPath: dir.appendingPathComponent("d.sock").path,
                stateURL: dir.appendingPathComponent("state.json")
            )
            try server.start()
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func seedWorkspace(on server: SessionServer) async throws -> (Space, Tab) {
        let space = Space(name: "workspace", path: "/tmp/workspace")
        let tab = Tab(
            spaceID: space.id,
            order: 0,
            layout: .leaf(LeafPane(cwd: space.path))
        )
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: []))
        return (space, tab)
    }

    /// A just-created agent wears the launch overlay until pi's status
    /// extension first reports — delivered over the same wiring a real
    /// report takes (session store callback → view model).
    @Test func launchOverlayLiftsOnFirstStatusReport() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let agentID = AgentID()

        vm.beginAgentLaunch(agentID)
        #expect(vm.launchingAgents.contains(agentID))

        vm.sessions.onAgentStatus?(agentID, .idle)
        #expect(vm.launchingAgents.isEmpty)

        // Explicit end (spawn failure, deletion) is idempotent.
        vm.beginAgentLaunch(agentID)
        vm.endAgentLaunch(agentID)
        vm.endAgentLaunch(agentID)
        #expect(vm.launchingAgents.isEmpty)
    }

    @Test func newChildBatchesStartCollapsed() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let agentID = AgentID()
        let child = ChildRun(runID: "run", label: "reviewer", state: "running")

        vm.applyAgentChildren(agentID, [child])
        #expect(vm.collapsedChildren.contains(agentID))

        vm.collapsedChildren.remove(agentID)
        vm.applyAgentChildren(agentID, [child])
        #expect(!vm.collapsedChildren.contains(agentID))

        vm.applyAgentChildren(agentID, [])
        vm.applyAgentChildren(agentID, [child])
        #expect(vm.collapsedChildren.contains(agentID))
    }

    @Test func injectedServerBootstrapsPersistedWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (space, tab) = try await seedWorkspace(on: fixture.server)

        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.spaces == [space] && vm.state.tabs == [tab] })
        #expect(vm.selectedSpaceID == space.id)
        #expect(vm.activeTabID == tab.id)
    }

    @Test func remoteSpaceCollapseSurvivesViewModelRestart() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let defaultsName = "shepherd.remote-space-collapse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let hostID = UUID()
        let otherHostID = UUID()
        let spaceID = SpaceID()

        var vm: ShepherdViewModel? = ShepherdViewModel(
            server: fixture.server,
            remoteHosts: RemoteHostStore(defaults: defaults),
            sidebarDefaults: defaults
        )
        vm?.toggleRemoteSpaceCollapsed(hostID: hostID, spaceID: spaceID)
        #expect(vm?.isRemoteSpaceCollapsed(hostID: hostID, spaceID: spaceID) == true)
        #expect(vm?.isRemoteSpaceCollapsed(hostID: otherHostID, spaceID: spaceID) == false)

        vm = nil
        let restored = ShepherdViewModel(
            server: fixture.server,
            remoteHosts: RemoteHostStore(defaults: defaults),
            sidebarDefaults: defaults
        )
        #expect(restored.isRemoteSpaceCollapsed(hostID: hostID, spaceID: spaceID))
        #expect(!restored.isRemoteSpaceCollapsed(hostID: otherHostID, spaceID: spaceID))
    }

    @Test func quickCreateWhileRemoteSelectedCreatesOnlyOnRemoteHost() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let remoteDir = URL(fileURLWithPath: "/tmp/shepherd-remote-vm-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        let remoteServer = SessionServer(
            socketPath: remoteDir.appendingPathComponent("d.sock").path,
            stateURL: remoteDir.appendingPathComponent("state.json")
        )
        try remoteServer.start()
        defer {
            remoteServer.stop()
            try? FileManager.default.removeItem(at: remoteDir)
        }

        let space = Space(name: "remote", path: "/remote/project")
        let pane = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(
            name: "remote worker",
            spaceID: space.id,
            tabID: tab.id,
            paneID: pane.id
        )
        try await remoteServer.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))

        let minted = AgentID()
        remoteServer.onRemoteCreateAgent = { request, completion in
            guard request.spaceID == space.id, request.cwd == space.path else {
                completion(.failure(RemoteCreateAgentError("wrong remote checkout")))
                return
            }
            completion(.success(minted))
        }
        let tokenURL = remoteDir.appendingPathComponent("remote-token")
        let port = try remoteServer.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let defaultsName = "shepherd.remote.quick-create.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let remoteHosts = RemoteHostStore(defaults: defaults)
        remoteHosts.addHost(name: "remote", host: "127.0.0.1", port: port, token: token)
        let hostID = try #require(remoteHosts.connections.first?.id)
        defer { remoteHosts.removeHost(id: hostID) }

        let vm = ShepherdViewModel(server: fixture.server, remoteHosts: remoteHosts)
        #expect(await waitUntil {
            remoteHosts.connections.first?.phase == .connected
                && remoteHosts.connections.first?.state.agents.first?.id == agent.id
        })
        vm.selectRemoteAgent(hostID: hostID, agentID: agent.id)

        vm.quickCreateAgent()

        #expect(await waitUntil {
            vm.selectedRemoteAgent == RemoteAgentRef(hostID: hostID, agentID: minted)
        })
        #expect(!vm.showNewAgentSheet)
        #expect(fixture.server.state.agents.isEmpty)
    }

    @Test func addSpaceWithoutInitialAgentCreatesOneAtomicWorkspaceSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let path = fixture.dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let id = await vm.addSpace(at: path, createInitialAgent: false)
        #expect(id != nil)
        #expect(fixture.server.state.spaces.count == 1)
        #expect(fixture.server.state.tabs.count == 1)
        #expect(fixture.server.state.agents.isEmpty)
        #expect(fixture.server.state.tabs.first?.spaceID == id)
        #expect(vm.selectedSpaceID == id)
    }

    @Test func worktreeImportPickerCapturesTheRegisteredWorktreeDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.dir.appendingPathComponent("repo", isDirectory: true)
        let worktreeFolder = fixture.dir.appendingPathComponent("linked", isDirectory: true)
        let worktree = worktreeFolder.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeFolder, withIntermediateDirectories: true)

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["worktree", "add", "-q", "-b", "worktree/feature", worktree.path])

        let vm = ShepherdViewModel(server: fixture.server)
        let spaceID = try #require(await vm.addSpace(at: repo, createInitialAgent: false))
        vm.importExistingWorktreeFromPanel(in: spaceID)

        guard case .importWorktree(let target) = vm.spacePickerTarget else {
            Issue.record("expected worktree import picker")
            return
        }
        #expect(target.spaceID == spaceID)
        #expect(target.startPath == worktreeFolder.resolvingSymlinksInPath().path)

        let firstRequest = target.id
        vm.spacePickerTarget = nil
        vm.importExistingWorktreeFromPanel(in: spaceID)
        guard case .importWorktree(let reopened) = vm.spacePickerTarget else {
            Issue.record("expected reopened worktree import picker")
            return
        }
        #expect(reopened.id != firstRequest)
    }

    @Test func importingExistingCheckoutRestoresWorktreeIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let repo = fixture.dir.appendingPathComponent("repo", isDirectory: true)
        let worktree = fixture.dir.appendingPathComponent("migrated-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["worktree", "add", "-q", "-b", "worktree/imported", worktree.path])

        let spaceID = await vm.addSpace(at: repo, createInitialAgent: false)
        let id = await vm.importExistingCheckout(at: worktree, into: spaceID)
        let agent = try #require(fixture.server.state.agents.first)

        #expect(id == agent.id)
        let canonicalRepo = repo.resolvingSymlinksInPath().path
        let canonicalWorktree = worktree.resolvingSymlinksInPath().path
        #expect(fixture.server.state.spaces.first?.path == canonicalRepo)
        #expect(agent.worktreeBranch == "worktree/imported")
        #expect(agent.worktreePath == canonicalWorktree)
        #expect(fixture.server.state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd == canonicalWorktree)
        #expect(vm.selectedAgentID == id)

        #expect(fixture.server.state.spaces.count == 1)
        #expect(fixture.server.state.agents.count == 1)
    }

    @Test func importingWorktreeRejectsAnotherSpacesRepository() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let firstRepo = fixture.dir.appendingPathComponent("first", isDirectory: true)
        let secondRepo = fixture.dir.appendingPathComponent("second", isDirectory: true)
        let worktree = fixture.dir.appendingPathComponent("second-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRepo, withIntermediateDirectories: true)

        func git(_ arguments: [String], in repo: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        for repo in [firstRepo, secondRepo] {
            try git(["init", "-q"], in: repo)
            try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        }
        try git(["worktree", "add", "-q", "-b", "worktree/wrong-space", worktree.path], in: secondRepo)
        let firstSpaceID = await vm.addSpace(at: firstRepo, createInitialAgent: false)

        #expect(await vm.importExistingCheckout(at: worktree, into: firstSpaceID) == nil)
        #expect(fixture.server.state.agents.isEmpty)
        #expect(fixture.server.state.spaces.count == 1)
    }

    @Test func settingsSectionSurvivesClosingUntilViewModelRestarts() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)

        #expect(vm.settingsSection == .appearance)
        vm.showSettings = true
        vm.settingsSection = .pi
        vm.showSettings = false
        vm.showSettings = true

        #expect(vm.settingsSection == .pi)
    }

    @Test func queuedLayoutWritesStayOrderedAndReconcileRejectedOptimisticState() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (space, tab) = try await seedWorkspace(on: fixture.server)
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.tabs.first?.id == tab.id })

        let first = LeafPane(cwd: space.path)
        let second = LeafPane(cwd: space.path)
        let committed = PaneNode.split(
            axis: .vertical,
            ratio: 0.6,
            first: .leaf(first),
            second: .leaf(second)
        )
        let rejected = PaneNode.split(
            axis: .vertical,
            ratio: 1.0,
            first: .leaf(first),
            second: .leaf(second)
        )

        vm.setLayout(committed, forTab: tab.id)
        vm.setLayout(rejected, forTab: tab.id)

        #expect(await waitUntil {
            fixture.server.state.tabs.first?.layout == committed
                && vm.state.tabs.first?.layout == committed
        })
    }

    @Test func structuralViewModelLayoutWritePreservesExistingSessionBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let sessionID = SessionID()
        let pane = LeafPane(sessionID: sessionID, cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await fixture.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: []))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.tabs.first?.id == tab.id })

        let requested = PaneNode.split(
            axis: .vertical,
            ratio: 0.5,
            first: .leaf(LeafPane(id: pane.id, cwd: space.path)),
            second: .leaf(LeafPane(cwd: space.path))
        )
        vm.setLayout(requested, forTab: tab.id)

        #expect(await waitUntil {
            fixture.server.state.tabs.first?.layout.leaf(withID: pane.id)?.sessionID == sessionID
                && fixture.server.state.tabs.first?.layout.leaves.count == 2
        })
    }

    @Test func agentOpenedPaneDoesNotStealTheUsersWorkspaceOrFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let backgroundID = AgentID()
        let visibleID = AgentID()
        let backgroundPane = LeafPane(cwd: space.path, agentID: backgroundID)
        let visiblePane = LeafPane(cwd: space.path, agentID: visibleID)
        let backgroundTab = Tab(spaceID: space.id, order: 0, layout: .leaf(backgroundPane))
        let visibleTab = Tab(spaceID: space.id, order: 1, layout: .leaf(visiblePane))
        let backgroundAgent = Agent(
            id: backgroundID,
            name: "background",
            spaceID: space.id,
            tabID: backgroundTab.id,
            paneID: backgroundPane.id
        )
        let visibleAgent = Agent(
            id: visibleID,
            name: "visible",
            spaceID: space.id,
            tabID: visibleTab.id,
            paneID: visiblePane.id
        )
        try await fixture.server.putState(ShepherdState(
            spaces: [space],
            tabs: [backgroundTab, visibleTab],
            agents: [backgroundAgent, visibleAgent]
        ))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 2 })
        vm.selectAgent(visibleID)
        vm.focusedPaneID = visiblePane.id

        fixture.server.onPaneRequest?(.open(
            agentID: backgroundID,
            axis: .vertical,
            cwd: nil,
            relativeTo: nil,
            command: nil
        )) { _ in }

        #expect(vm.selectedAgentID == visibleID)
        #expect(vm.focusedPaneID == visiblePane.id)
        #expect(vm.state.tabs.first(where: { $0.id == backgroundTab.id })?.layout.leaves.count == 2)
    }

    @Test func paneControlRejectsForeignAndOwnPaneButClosesAuxiliaryPane() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let agentID = AgentID()
        let primary = LeafPane(cwd: space.path, agentID: agentID)
        let auxiliary = LeafPane(cwd: space.path)
        let tab = Tab(
            spaceID: space.id,
            order: 0,
            layout: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(primary),
                second: .leaf(auxiliary)
            )
        )
        let agent = Agent(
            id: agentID,
            name: "worker",
            spaceID: space.id,
            tabID: tab.id,
            paneID: primary.id
        )
        try await fixture.server.putState(
            ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        )
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.first?.id == agentID })

        var ownOutcome: PaneOutcome?
        fixture.server.onPaneRequest?(.close(agentID: agentID, paneID: primary.id)) {
            ownOutcome = $0
        }
        #expect(ownOutcome == .failed(
            code: "not_closable",
            message: "an agent cannot close its own pi pane"
        ))

        let foreignPaneID = PaneID()
        var foreignOutcome: PaneOutcome?
        fixture.server.onPaneRequest?(.close(agentID: agentID, paneID: foreignPaneID)) {
            foreignOutcome = $0
        }
        #expect(foreignOutcome == .failed(
            code: "no_such_pane",
            message: "pane \(foreignPaneID) is not in this agent's layout"
        ))

        var auxiliaryOutcome: PaneOutcome?
        fixture.server.onPaneRequest?(.close(agentID: agentID, paneID: auxiliary.id)) {
            auxiliaryOutcome = $0
        }
        #expect(auxiliaryOutcome == .ok)
        #expect(await waitUntil {
            fixture.server.state.tabs.first?.layout.leaves.map(\.id) == [primary.id]
        })
    }

    @Test func resetSettingsRestoresPreferencesAndRebuildsSurfaces() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)

        let settings = AppSettings.shared
        let originalFontFamily = settings.terminalFontFamily
        let originalFontSize = settings.terminalFontSize
        let originalModel = settings.defaultModel
        let originalThinking = settings.defaultThinking
        let originalAutoName = settings.autoNameAgents
        let originalShell = settings.shellPath
        let keys = KeybindingsStore.shared
        let originalOverrides = keys.overrides
        let originalAppearance = ThemeManager.shared.mode
        defer {
            settings.terminalFontFamily = originalFontFamily
            settings.terminalFontSize = originalFontSize
            settings.defaultModel = originalModel
            settings.defaultThinking = originalThinking
            settings.autoNameAgents = originalAutoName
            settings.shellPath = originalShell
            keys.resetAll()
            for (action, chord) in originalOverrides {
                _ = keys.assign(chord, to: action)
            }
            ThemeManager.shared.select(originalAppearance)
        }

        settings.terminalFontSize = 20
        settings.defaultModel = "openai/gpt-5"
        settings.autoNameAgents = false
        _ = keys.assign(KeyChord(key: "p", command: true), to: .newAgent)
        ThemeManager.shared.select(.light)

        vm.resetSettings()

        #expect(settings.terminalFontFamily == AppSettings.Defaults.terminalFontFamily)
        #expect(settings.terminalFontSize == AppSettings.Defaults.terminalFontSize)
        #expect(settings.defaultModel.isEmpty)
        #expect(settings.defaultThinking == AppSettings.Defaults.thinking)
        #expect(settings.autoNameAgents)
        #expect(settings.shellPath == AppSettings.Defaults.shellPath)
        #expect(keys.overrides.isEmpty)
        let launchTheme = ProcessInfo.processInfo.environment["SHEPHERD_THEME"]
        let launchMode: AppearanceMode = launchTheme == "basalt-light"
            ? .light
            : ["basalt-dark", "shepherd-dark"].contains(launchTheme) ? .dark : .system
        #expect(ThemeManager.shared.mode == launchMode)
    }

    @Test func resetSettingsFailureLeavesIsolatedStoresUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let settingsName = "shepherd.vm.settings.\(UUID().uuidString)"
        let keyName = "shepherd.vm.keys.\(UUID().uuidString)"
        let themeName = "shepherd.vm.theme.\(UUID().uuidString)"
        let settingsDefaults = UserDefaults(suiteName: settingsName)!
        let keyDefaults = UserDefaults(suiteName: keyName)!
        let themeDefaults = UserDefaults(suiteName: themeName)!
        defer {
            settingsDefaults.removePersistentDomain(forName: settingsName)
            keyDefaults.removePersistentDomain(forName: keyName)
            themeDefaults.removePersistentDomain(forName: themeName)
        }

        let settings = AppSettings(store: settingsDefaults)
        settings.terminalFontSize = 20
        settings.defaultModel = "openai/gpt-5"
        settings.autoNameAgents = false
        let keys = KeybindingsStore(store: keyDefaults)
        _ = keys.assign(KeyChord(key: "p", command: true), to: .newAgent)
        let themeManager = ThemeManager(
            store: themeDefaults,
            environmentTheme: nil,
            systemColorScheme: .dark
        )
        themeManager.select(.light)

        let vm = ShepherdViewModel(
            server: fixture.server,
            settings: settings,
            keybindings: keys,
            themeManager: themeManager,
            themeInstaller: { _ in throw NSError(domain: "theme-test", code: 1) }
        )

        vm.resetSettings()

        #expect(settings.terminalFontSize == 20)
        #expect(settings.defaultModel == "openai/gpt-5")
        #expect(settings.autoNameAgents == false)
        #expect(keys.overrides[.newAgent] == KeyChord(key: "p", command: true))
        #expect(themeManager.current.id == "basalt-light")
    }

    /// Worktree agents lead their space's list (stable within each group) so
    /// they read as part of the checkout tree, not standard agents.
    @Test func worktreeAgentsSortFirstInTheirSpace() {
        let space = SpaceID(rawValue: "s")
        let tab = TabID(rawValue: "t")
        let agents = [
            Agent(name: "one", spaceID: space, tabID: tab),
            Agent(name: "wt-1", spaceID: space, tabID: tab, worktreeBranch: "worktree/wt-1"),
            Agent(name: "two", spaceID: space, tabID: tab),
            Agent(name: "wt-2", spaceID: space, tabID: tab, worktreeBranch: "worktree/wt-2"),
            Agent(name: "elsewhere", spaceID: SpaceID(rawValue: "x"), tabID: tab),
        ]
        let ordered = ShepherdViewModel.sidebarAgents(of: space, in: agents)
        #expect(ordered.map(\.name) == ["wt-1", "wt-2", "one", "two"])
    }

    @Test func orderedAgentsOmitsDescendantsOfCollapsedSpace() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let root = Space(name: "root", path: "/tmp/root")
        let child = Space(name: "child", path: "/tmp/root/child")
        let other = Space(name: "other", path: "/tmp/other")
        let rootTab = Tab(spaceID: root.id, order: 0, layout: .leaf(LeafPane(cwd: root.path)))
        let childTab = Tab(spaceID: child.id, order: 0, layout: .leaf(LeafPane(cwd: child.path)))
        let otherTab = Tab(spaceID: other.id, order: 0, layout: .leaf(LeafPane(cwd: other.path)))
        let agents = [
            Agent(name: "root-agent", spaceID: root.id, tabID: rootTab.id),
            Agent(name: "child-agent", spaceID: child.id, tabID: childTab.id),
            Agent(name: "other-agent", spaceID: other.id, tabID: otherTab.id),
        ]
        try await fixture.server.putState(
            ShepherdState(
                spaces: [root, child, other],
                tabs: [rootTab, childTab, otherTab],
                agents: agents
            )
        )
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.orderedAgents.map(\.name) == ["root-agent", "child-agent", "other-agent"] })

        vm.toggleSpaceCollapsed(root.id)

        #expect(vm.orderedAgents.map(\.name) == ["other-agent"])
    }

    @Test func adjacentAgentSelectionFollowsVisibleSidebarOrderAndWraps() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let tabs = (0..<3).map { Tab(spaceID: space.id, order: $0, layout: .leaf(LeafPane(cwd: space.path))) }
        let agents = zip(["one", "two", "three"], tabs).map { name, tab in
            Agent(name: name, spaceID: space.id, tabID: tab.id)
        }
        try await fixture.server.putState(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.orderedAgents.count == 3 })

        vm.selectAgent(agents[0].id)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == agents[1].id)
        vm.selectAdjacentAgent(1)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == agents[0].id)
        vm.selectAdjacentAgent(-1)
        #expect(vm.selectedAgentID == agents[2].id)
    }

    @Test func appearanceModePersistsResetsAndFollowsSystem() {
        let name = "shepherd.theme.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let manager = ThemeManager(
            store: defaults,
            environmentTheme: nil,
            systemColorScheme: .dark
        )
        #expect(manager.mode == .system)
        #expect(manager.current.id == "basalt-dark")

        manager.select(.light)
        #expect(manager.current.id == "basalt-light")
        #expect(defaults.string(forKey: "shepherd.appearance") == "light")

        #expect(manager.resetToDefault().id == "basalt-dark")
        #expect(manager.mode == .system)
        #expect(defaults.object(forKey: "shepherd.appearance") == nil)

        #expect(manager.updateSystemColorScheme(.light)?.id == "basalt-light")
        #expect(manager.current.id == "basalt-light")

        let overridden = ThemeManager(
            store: defaults,
            environmentTheme: "basalt-dark",
            systemColorScheme: .light
        )
        #expect(overridden.mode == .dark)
        #expect(overridden.current.id == "basalt-dark")
        #expect(overridden.resetToDefault().id == "basalt-dark")
    }
}

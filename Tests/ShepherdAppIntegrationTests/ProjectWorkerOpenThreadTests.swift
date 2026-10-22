import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

/// Open as a thread, the task detail's header button and its More menu item, on real workers: an owner-local one, one the owner
/// placed on a loopback executor, and both seen from a viewer of a remote owner. It follows the owner's record of where the worker
/// runs (owner-relative host and binding), never an agent-ID search or a local agent with the same ID, and says so when that route is
/// gone. Opening only changes selection: the task stays resolved and nothing is sent or started.
@Suite("Project Open as a thread", .mainActorExclusive)
@MainActor
struct ProjectWorkerOpenThreadTests {
    @MainActor private final class Rig {
        let owner: AppHarness
        let executor: AppHarness
        let local: Space
        let remote: Space
        var binding: ProjectHostReference = .local
        var executorHostID = UUID()
        let projectID = ProjectID()
        var project: Project { owner.server.state.projects.first { $0.id == projectID }! }

        init() throws {
            AccessibilityNode.enable()
            let catalog: SessionServer.ModelCatalog = { .init(models: ["anthropic/claude-sonnet-4-5"], defaultModel: "anthropic/claude-sonnet-4-5") }
            owner = try AppHarness(modelCatalog: catalog)
            executor = try AppHarness(modelCatalog: catalog)
            owner.settings.projectsEnabled = true; executor.settings.projectsEnabled = true
            local = Space(name: "Owner", path: owner.dir.path)
            remote = Space(name: "Executor", path: executor.dir.path)
        }

        func start() async throws {
            try StubPi.installAsEngine()
            try Data(#"{"model":{"provider":"anthropic","id":"claude-sonnet-4-5"}}"#.utf8).write(to: executor.dir.appendingPathComponent("stub-pi-startup.json"))
            _ = try await owner.start(); _ = try await executor.start()
            try await owner.server.addSpace(local); try await executor.server.addSpace(remote)
            let tokenURL = executor.dir.appendingPathComponent("open-thread-token")
            let port = try executor.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            owner.remoteHosts.addHost(name: "Fixture executor", host: "127.0.0.1", port: port, token: token)
            try await eventuallyOnMain("loopback executor connected") { self.owner.remoteHosts.connections.first?.phase == .connected }
            let config = try #require(owner.remoteHosts.hosts.first)
            executorHostID = config.id
            binding = .remote(hostID: config.id, bindingID: config.bindingID)
            _ = try await owner.server.logicalProjects(.create(projectID: projectID, name: "Owner Project", goal: "", linkedSpaceIDs: [local.id]))
            _ = try await owner.server.logicalProjects(.settings(projectID: projectID, expectedRevision: project.revision,
                settings: .init(threadModel: "anthropic/claude-sonnet-4-5", allowedHosts: [.local, binding])))
            _ = try await owner.server.logicalProjects(.linkSpace(projectID: projectID, expectedRevision: project.revision, spaceID: remote.id, host: binding))
        }

        /// A real worker, settled then resolved by the owner.
        func resolvedTask(remote placed: Bool) async throws -> ProjectTask {
            let before = Set(project.tasks.map(\.id))
            _ = try await owner.vm.projectCoordinator.perform(projectID: projectID, expectedRevision: project.revision, request: .assign(
                operationID: UUID(), spaceID: placed ? remote.id : local.id, title: placed ? "Remote work" : "Local work", prompt: "tools:0",
                host: placed ? binding : nil))
            let id = try #require(project.tasks.first { !before.contains($0.id) }?.id)
            try await eventuallyOnMain("the worker settles") { self.project.tasks.first { $0.id == id }?.phase == .settled }
            _ = try await owner.vm.projectCoordinator.perform(projectID: projectID, expectedRevision: project.revision, request: .resolve(taskID: id))
            return try #require(project.tasks.first { $0.id == id && $0.phase == .resolved })
        }

        func stop() { owner.stop(); executor.stop() }
    }

    /// What must not move when a thread is opened: the Project record and every agent on both Macs.
    private struct Untouched: Equatable {
        let project: Project
        let ownerAgents: [AgentID]
        let executorAgents: [AgentID]
        @MainActor init(_ r: Rig) { project = r.project; ownerAgents = r.owner.server.state.agents.map(\.id); executorAgents = r.executor.server.state.agents.map(\.id) }
    }

    /// The production task detail for `task`, as the pane mounts it.
    private static func detail(_ vm: ShepherdViewModel, _ ref: LogicalProjectRef, _ task: ProjectTaskID) throws -> OffscreenWindow {
        vm.openLogicalProject(ref); vm.logicalProjectPaneTask = task
        let project = try #require(vm.logicalProjects.project(ref))
        let row = try #require(ProjectPagePresentation(project).rows.first { $0.id == task })
        return OffscreenWindow(size: CGSize(width: 640, height: 900), dark: false, ProjectTaskDetail(vm: vm, ref: ref, project: project, task: row))
    }

    /// An ordinary owner-local thread with `id`, the remote worker's agent ID.
    private static func addLocalDecoy(_ id: AgentID, in r: Rig) async throws {
        let pane = LeafPane(cwd: r.local.path, agentID: id)
        let tab = Tab(spaceID: r.local.id, order: 0, layout: .leaf(pane))
        var state = r.owner.server.state
        state.tabs.append(tab)
        state.agents.append(Agent(id: id, name: "Local decoy", spaceID: r.local.id, tabID: tab.id, paneID: pane.id))
        try await r.owner.server.putState(state)
        try await eventuallyOnMain("the decoy reaches the view model") { r.owner.vm.state.agents.contains { $0.id == id } }
    }

    private static func pressOpen(_ window: OffscreenWindow) async throws {
        try await eventuallyOnMain("the Open as a thread button") { window.layout(); return window.element("Open as a thread") != nil }
        try window.press("Open as a thread")
    }

    @Test func theHeaderButtonOpensAnOwnerLocalResolvedWorker() async throws {
        let r = try Rig(); defer { r.stop() }
        try await r.start()
        let task = try await r.resolvedTask(remote: false)
        let window = try Self.detail(r.owner.vm, .init(home: .local, id: r.projectID), task.id); defer { window.close() }
        let before = Untouched(r)
        try await Self.pressOpen(window)
        #expect(r.owner.vm.selectedAgentID == task.workerAgentID && r.owner.vm.selectedRemoteAgent == nil)
        #expect(r.owner.vm.destination == nil, "Open as a thread leaves the Project page")
        #expect(Untouched(r) == before, "opening history neither reopens the task nor starts anything")
        #expect(r.owner.vm.remoteActionError == nil)
    }

    /// The executor's worker, by the task's own binding. A local agent with the worker's ID is a collision, never a fallback.
    @Test func theHeaderButtonOpensTheExecutorsResolvedWorkerAndNeverALocalAgentWithItsID() async throws {
        let r = try Rig(); defer { r.stop() }
        try await r.start()
        let task = try await r.resolvedTask(remote: true)
        #expect(!r.owner.server.state.agents.contains { $0.id == task.workerAgentID } && r.executor.server.state.agents.contains { $0.id == task.workerAgentID })
        // The collision: an ordinary local thread that happens to carry the remote worker's ID.
        try await Self.addLocalDecoy(task.workerAgentID, in: r)
        let selectedLocal = r.owner.vm.selectedAgentID

        let window = try Self.detail(r.owner.vm, .init(home: .local, id: r.projectID), task.id); defer { window.close() }
        let before = Untouched(r)
        try await Self.pressOpen(window)
        #expect(r.owner.vm.selectedRemoteAgent == RemoteAgentRef(hostID: r.executorHostID, agentID: task.workerAgentID), "the executor's own worker")
        #expect(r.owner.vm.selectedAgentID == selectedLocal, "the local decoy is not selected")
        #expect(r.owner.vm.destination == nil, "Open as a thread leaves the Project page")
        #expect(Untouched(r) == before, "opening history neither reopens the task nor starts anything")
        #expect(r.owner.vm.remoteActionError == nil)
    }

    /// The task's exact binding is gone (the host was re-pointed, then removed). Each press says so; nothing is selected, not even the
    /// local agent with the worker's ID, and the Project page stays.
    @Test func aChangedOrRemovedExecutorBindingSaysSoAndSelectsNothing() async throws {
        let r = try Rig(); defer { r.stop() }
        try await r.start()
        let task = try await r.resolvedTask(remote: true)
        let config = try #require(r.owner.remoteHosts.hosts.first)
        let window = try Self.detail(r.owner.vm, .init(home: .local, id: r.projectID), task.id); defer { window.close() }
        let before = Untouched(r)

        // Same host ID, new binding: another endpoint now answers to that name, so the old route is not followed.
        r.owner.remoteHosts.updateHost(id: config.id, name: config.name, host: config.host, port: config.port, token: config.token + "-rotated")
        #expect(r.owner.remoteHosts.hosts.first?.bindingID != config.bindingID)
        try await Self.pressOpen(window)
        #expect(r.owner.vm.remoteActionError?.contains("no longer set up") == true, "\(r.owner.vm.remoteActionError ?? "nil")")
        #expect(r.owner.vm.selectedRemoteAgent == nil && r.owner.vm.destination == .project)
        r.owner.vm.remoteActionError = nil

        r.owner.remoteHosts.removeHost(id: config.id)
        try await Self.addLocalDecoy(task.workerAgentID, in: r)
        let selectedLocal = r.owner.vm.selectedAgentID
        try window.press("Open as a thread")
        #expect(r.owner.vm.remoteActionError != nil, "a removed host is said, not silently ignored")
        #expect(r.owner.vm.selectedRemoteAgent == nil && r.owner.vm.selectedAgentID == selectedLocal, "no local fallback by agent ID")
        #expect(r.owner.vm.destination == .project)
        #expect(r.project == before.project && r.executor.server.state.agents.map(\.id) == before.executorAgents)
    }

    /// A viewer of a remotely owned Project: the owner's own worker is that host's agent, opened through the viewer's connection to the
    /// owner. A worker the owner placed on its executor has a host ID only the owner can read, so the viewer says so instead of guessing.
    @Test func aViewerOpensTheRemoteOwnersWorkerAndSaysWhenTheOwnerPlacedItElsewhere() async throws {
        let r = try Rig(); defer { r.stop() }
        try await r.start()
        let ownerWorker = try await r.resolvedTask(remote: false)
        let placed = try await r.resolvedTask(remote: true)

        let viewer = try AppHarness(); defer { viewer.stop() }
        viewer.settings.projectsEnabled = true
        _ = try await viewer.start()
        let tokenURL = r.owner.dir.appendingPathComponent("viewer-token")
        let port = try r.owner.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        viewer.remoteHosts.addHost(name: "Owner Mac", host: "127.0.0.1", port: port, token: token)
        let ownerHost = try #require(viewer.remoteHosts.hosts.first).id
        let ref = LogicalProjectRef(home: .host(ownerHost), id: r.projectID)
        try await eventuallyOnMain("the viewer sees the owner's resolved tasks and its worker") {
            viewer.vm.logicalProjects.project(ref)?.tasks.filter { $0.phase == .resolved }.count == 2
                && viewer.vm.remoteAgent(RemoteAgentRef(hostID: ownerHost, agentID: ownerWorker.workerAgentID)) != nil
        }
        let before = Untouched(r)

        let window = try Self.detail(viewer.vm, ref, ownerWorker.id); defer { window.close() }
        try await Self.pressOpen(window)
        #expect(viewer.vm.selectedRemoteAgent == RemoteAgentRef(hostID: ownerHost, agentID: ownerWorker.workerAgentID), "the owner's worker, by the owner's host")
        #expect(viewer.vm.destination == nil)
        #expect(viewer.vm.remoteActionError == nil)

        let elsewhere = try Self.detail(viewer.vm, ref, placed.id); defer { elsewhere.close() }
        try await Self.pressOpen(elsewhere)
        #expect(viewer.vm.remoteActionError?.contains("Owner Mac") == true, "\(viewer.vm.remoteActionError ?? "nil")")
        #expect(viewer.vm.selectedRemoteAgent == nil && viewer.vm.destination == .project, "nothing is selected by the owner's host ID")
        #expect(Untouched(r) == before, "neither open reopens a task nor starts anything")
    }

    /// The More menu's item runs the same route. One native menu per process (`NativeMenuChoice` leaves tracking open).
    @Test func theMoreMenuOpensTheExecutorsResolvedWorker() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.moreMenu() } }
        expectScenarioCompleted(result)
    }

    private static func moreMenu() async throws {
        let r = try Rig(); defer { r.stop() }
        try await r.start()
        let task = try await r.resolvedTask(remote: true)
        let window = try detail(r.owner.vm, .init(home: .local, id: r.projectID), task.id); defer { window.close() }
        try await eventuallyOnMain("the More menu") { window.layout(); return more(window) != nil }
        let before = Untouched(r)
        let offered = try await NativeMenuChoice.choose("Open as a thread", from: try #require(more(window)))
        #expect(offered == ["Open as a thread"], "a resolved task offers only Open as a thread: \(offered)")
        try await eventuallyOnMain("the executor's worker is selected") {
            r.owner.vm.selectedRemoteAgent == RemoteAgentRef(hostID: r.executorHostID, agentID: task.workerAgentID)
        }
        #expect(r.owner.vm.destination == nil)
        #expect(Untouched(r) == before, "opening history neither reopens the task nor starts anything")
        #expect(r.owner.vm.remoteActionError == nil)
    }

    /// SwiftUI names this Menu by its help, not its label.
    private static func more(_ window: OffscreenWindow) -> AccessibilityNode? {
        window.elements().first { node in
            node.role == ControlRole.menuButton
                && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == "More"
        }
    }
}

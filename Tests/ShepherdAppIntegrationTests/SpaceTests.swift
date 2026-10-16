import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Adding, renaming, and deleting spaces through the view model.
@Suite("Spaces", .mainActorExclusive)
@MainActor
struct SpaceTests {
    /// Adding a folder makes a project and opens New thread in it: no agent starts until you send.
    @Test func addingASpaceCreatesOnlyTheSpaceAndOpensNewThreadInIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let checkout = app.dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)

        let id = try #require(await vm.addSpace(at: checkout))

        #expect(app.server.state.spaces.map(\.id) == [id])
        #expect(app.server.state.spaces.first?.name == "checkout")
        #expect(app.server.state.tabs.isEmpty && app.server.state.agents.isEmpty)
        #expect(vm.selectedSpaceID == id && vm.selectedAgentID == nil)
        #expect(vm.shownDestination == .newThread)
        #expect(vm.newThread.place == NewThreadPlace(host: nil, space: id))
    }

    @Test func aCheckoutWithAWorktreeOperationRunningCannotBecomeASpace() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.hostBusyWorktrees.insert(canonical(app.dir))

        #expect(await vm.addSpace(at: app.dir) == nil)

        #expect(vm.remoteActionError != nil)
        #expect(app.server.state.spaces.isEmpty)
    }

    @Test func renamingASpaceChangesOnlyItsLabel() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("repo", path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        vm.renameSpace(space.id, to: "  Billing service ")
        await app.settle()

        #expect(app.server.state.spaces.first?.name == "Billing service")
        #expect(app.server.state.spaces.first?.path == space.path)
        #expect(app.server.state.tabs.first?.layout == agent.tab.layout)
    }

    @Test func deletingASpaceStopsItsAgentsButKeepsSpacesNestedInIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("parent", path: app.dir.path)
        let nested = Fixture.space("nested", path: app.dir.appendingPathComponent("nested").path)
        let doomed = try await app.liveAgent("doomed", in: parent)
        let survivor = Fixture.agent("survivor", in: nested)
        let vm = try await app.start(with: Fixture.state(spaces: [parent, nested], agents: [doomed, survivor]))
        vm.selectAgent(doomed.agent.id)

        vm.deleteSpace(parent.id)
        await app.settle()

        #expect(app.server.state.spaces.map(\.id) == [nested.id])
        #expect(app.server.state.agents.map(\.id) == [survivor.agent.id])
        #expect(app.server.state.tabs.map(\.id) == [survivor.tab.id])
        #expect(vm.selectedSpaceID == nested.id && vm.selectedAgentID == survivor.agent.id)
        let server = app.server, session = try #require(doomed.piPane.sessionID)
        try await eventuallyAsync("the deleted space's pi to stop") { await server.sessionInfo(sessionID: session)?.isAlive != true }
    }

    /// With the last project gone, nothing is selected: never the reserved designs space.
    @Test func deletingTheLastSpaceNeverSelectsTheDesignsSpace() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("repo", path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let designs = try await app.server.designsSpaceID()
        vm.adopt(app.server.state)
        vm.selectAgent(agent.agent.id)
        #expect(vm.selectedSpaceID == space.id)

        vm.deleteSpace(space.id)
        await app.settle()

        #expect(app.server.state.spaces.map(\.id) == [designs])
        #expect(vm.selectedSpaceID == nil && vm.selectedAgentID == nil)
    }

    // MARK: Missing folders

    /// A space whose folder moves away is marked within the watch's interval, takes no thread,
    /// and Locate Folder… points it (and a child space inside it) at the folder's new place.
    @Test func aSpaceWhoseFolderMovesIsMarkedRefusesThreadsAndCanBeLocated() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fm = FileManager.default
        let folder = app.dir.appendingPathComponent("monitor", isDirectory: true)
        let child = folder.appendingPathComponent("web", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let parent = Fixture.space("monitor", path: canonical(folder))
        let nested = Fixture.space("web", path: canonical(child))
        let vm = try await app.start(with: Fixture.state(spaces: [parent, nested], agents: []))
        vm.installMissingSpaceWatch()
        try await eventuallyOnMain("both folders present") { vm.missingSpaces.isEmpty }

        let moved = app.dir.appendingPathComponent("archive/monitor", isDirectory: true)
        try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: moved)
        try await eventuallyOnMain("the move to be seen", timeout: .seconds(5)) { vm.missingSpaces == [parent.id, nested.id] }

        let row = try #require(vm.sidebarTree.projects.first { $0.space == parent.id })
        #expect(row.missing && row.newThreadPlace(connected: []) == nil)
        await #expect(throws: AgentStartFailure.self) {
            try await vm.startAgent(NewAgentConfig(spaceID: parent.id, workingDirectory: parent.path, model: nil, thinking: .medium, initialPrompt: nil),
                                    selectAfter: false)
        }
        #expect(app.server.state.agents.isEmpty)

        await vm.relocateSpace(parent.id, to: moved.path)

        let spaces = Dictionary(uniqueKeysWithValues: app.server.state.spaces.map { ($0.id, $0.path) })
        #expect(spaces[parent.id] == canonical(moved) && spaces[nested.id] == canonical(moved) + "/web")
        try await eventuallyOnMain("the space to be found again") { vm.missingSpaces.isEmpty }
    }

    /// Locating a space with a thread moves the thread with it: its pane's folder, and its
    /// conversation to the new folder's session folder with the header's cwd rewritten.
    @Test func locatingASpaceMovesItsThreadsAndTheirConversations() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fm = FileManager.default
        let folder = app.dir.appendingPathComponent("monitor", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Fixture.space("monitor", path: canonical(folder))
        let thread = Fixture.agent("old", in: space)
        let root = app.server.pi.sessionsRoot
        let sessionID = thread.agent.effectivePiSessionID
        let oldDirectory = PiSessionFile.projectDirectory(forCwd: space.path, sessionsRoot: root)
        try fm.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let header = #"{"cwd":"\#(space.path)","id":"\#(sessionID)","type":"session","version":3}"#
        try Data((header + "\n" + #"{"type":"message","message":{"role":"user","content":"hi"}}"# + "\n").utf8)
            .write(to: oldDirectory.appendingPathComponent("2026_\(sessionID).jsonl"))
        let moved = app.dir.appendingPathComponent("archive/monitor", isDirectory: true)
        try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: moved)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread]))

        await vm.relocateSpace(space.id, to: moved.path)

        #expect(vm.remoteActionError == nil)
        #expect(app.server.state.spaces.first?.path == canonical(moved))
        let pane = app.server.state.tabs.first?.layout.leaf(withID: thread.piPane.id)
        #expect(pane?.cwd == canonical(moved))
        #expect(app.server.state.agents.map(\.id) == [thread.agent.id])
        let file = try #require(PiSessionFile.file(sessionID: sessionID, cwd: canonical(moved), sessionsRoot: root))
        let text = try String(contentsOf: file, encoding: .utf8)
        let first = try #require(text.split(separator: "\n").first)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(parsed["cwd"] as? String == PiSessionFile.realPath(moved.path) && text.contains("hi"))
        #expect(PiSessionFile.file(sessionID: sessionID, cwd: space.path, sessionsRoot: root) == nil)
    }
}

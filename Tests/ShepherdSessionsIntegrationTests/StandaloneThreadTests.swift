import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Standalone threads", .integrationTimeLimit)
struct StandaloneThreadTests {
    @Test func threadsKeepSeparateFoldersAndSurviveRestartWhileAutomationRunsDoNot() async throws {
        let first = try ScratchServer.fresh()
        defer { first.stop() }
        let agentID = AgentID()
        let folder = try await first.server.standaloneThreadFolder(for: agentID)
        let other = try await first.server.standaloneThreadFolder(for: AgentID())
        #expect(folder.spaceID == other.spaceID && folder.directory != other.directory)
        #expect(FileManager.default.fileExists(atPath: folder.directory))
        let space = try #require(first.server.state.spaces.first { $0.id == folder.spaceID })
        #expect(space.hidden && space.holdsThreads && !space.holdsAutomations)
        let pane = LeafPane(cwd: folder.directory, agentID: agentID)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "Research", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await first.server.addAgent(agent, withTab: tab)
        let note = URL(fileURLWithPath: folder.directory).appendingPathComponent("notes.txt")
        try "Keep this".write(to: note, atomically: true, encoding: .utf8)
        let automations = Space(name: "Automations", path: "~", hidden: true)
        try await first.server.addSpace(automations)
        let run = Fixture.agent(in: automations)
        try await first.server.addAgent(run.agent, withTab: run.tab)
        first.stop(keepFiles: true)

        let restarted = try ScratchServer(dir: first.dir)
        defer { restarted.stop() }
        #expect(restarted.server.state.agents.map(\.id) == [agentID])
        #expect(restarted.server.state.tabs.first { $0.id == tab.id }?.layout.leaves.first?.cwd == folder.directory)
        #expect(try String(contentsOf: note, encoding: .utf8) == "Keep this")
        #expect(try restarted.persisted() == restarted.server.state.persisted)
        try restarted.server.state.validate()
    }

    @Test func folderIDsCannotEscapeThreadStorage() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        await #expect(throws: CocoaError.self) {
            try await h.server.standaloneThreadFolder(for: AgentID(rawValue: "../../outside"))
        }
        #expect(h.server.state.spaces.isEmpty)
    }
}

import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport

/// A long pi session answers `get_messages` with one multi-megabyte record. The reader once
/// dropped anything over the 1 MiB network frame cap, and the thread showed no history at all.
@Suite("Large session history", .integrationTimeLimit)
struct LargeHistoryTests {
    @Test func aMultiMegabyteHistoryReplyStillLoadsTheThread() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let space = Space(name: "big", path: scratch.dir.path)
        let session = try await scratch.server.createSession(params: CreateSessionParams(
            cwd: scratch.dir.path, command: StubPi.command,
            env: ["STUB_PI_HISTORY_BYTES": String(6 * 1024 * 1024)], runtime: .rpc))
        let pane = LeafPane(sessionID: session.id, cwd: scratch.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "big", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await scratch.server.addSpace(space)
        try await scratch.server.addAgent(agent, withTab: tab)

        var latest: NativeThreadSnapshot?
        try await eventually("the seeded history to load", timeout: .seconds(30)) {
            guard case .snapshot(let snapshot) = try await scratch.server.nativeThread(agentID: agent.id, request: .snapshot()) else { return false }
            latest = snapshot
            return snapshot.messages.contains { $0.blocks.contains { $0.text == "seeded reply" } }
        }
        // The page sent to clients stays bounded even though pi's reply was not.
        let page = try #require(latest)
        #expect(try JSONEncoder().encode(page).count < 256 * 1024)
    }
}

import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
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

    /// A long history decodes off the server queue: while it is held mid-decode, another agent's
    /// thread and a terminal's echo are still served.
    @Test func theServerQueueServesOtherAgentsWhileAHistoryDecodes() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let other = try await PiAgent.launch(on: scratch)
        _ = try await other.ready()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let armed = Locked(true)
        scratch.server.beforeOffQueueDecode = {
            guard armed.withValue({ armed in defer { armed = false }; return armed }) else { return }
            started.signal()
            release.wait()
        }
        let big = try await PiAgent.launch(on: scratch, env: ["STUB_PI_HISTORY_BYTES": String(6 * 1024 * 1024)])
        #expect(try await blocking { started.wait(timeout: .now() + 30) == .success }, "the history reached the decoder")

        #expect(try await other.request(.snapshot()).snapshotValue != nil)
        let shell = try await scratch.shell("cat")
        scratch.server.write(sessionID: shell.id, data: Data("ping\n".utf8))
        try await scratch.waitForScreen(shell.id, toContain: "ping")
        #expect(try await big.request(.snapshot()).failureCode == NativeThreadCode.starting, "the history is still decoding")

        release.signal()
        _ = try await big.snapshot("the history to load", timeout: .seconds(30)) {
            $0.messages.contains { $0.blocks.contains { $0.text == "seeded reply" } }
        }
    }
}

import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// An RPC agent on a scratch server: the stub pi in its own pane, with its stdin logged.
struct PiAgent {
    let host: ScratchServer
    let agent: Agent
    let sessionID: SessionID
    let log: URL

    var server: SessionServer { host.server }

    /// `env` adds to the stub's environment (its `STUB_PI_STARTUP_*` options, for one).
    static func launch(on host: ScratchServer, env: [String: String] = [:]) async throws -> PiAgent {
        let log = host.dir.appendingPathComponent("stdin-\(UUID().uuidString.prefix(6)).log")
        let session = try await host.server.createSession(params: CreateSessionParams(
            cwd: host.dir.path, command: StubPi.command, env: env.merging(["STUB_PI_LOG": log.path]) { $1 }, runtime: .rpc))
        let existing = host.server.state.spaces.first { $0.path == host.dir.path }
        let space = existing ?? Space(name: "rpc", path: host.dir.path)
        if existing == nil { try await host.server.addSpace(space) }
        let pane = LeafPane(sessionID: session.id, cwd: host.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "rpc", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await host.server.addAgent(agent, withTab: tab)
        return PiAgent(host: host, agent: agent, sessionID: session.id, log: log)
    }

    func request(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
        try await server.nativeThread(agentID: agent.id, request: request)
    }

    /// The first snapshot satisfying `condition`, polling until it appears.
    func snapshot(
        _ what: String = "the expected snapshot",
        timeout: Duration = .seconds(15),
        where condition: (NativeThreadSnapshot) -> Bool = { _ in true }
    ) async throws -> NativeThreadSnapshot {
        var match: NativeThreadSnapshot?
        try await eventually(what, timeout: timeout) {
            guard let value = try await request(.snapshot()).snapshotValue, condition(value) else { return false }
            match = value
            return true
        }
        return try #require(match)
    }

    /// Once pi has reported its session and history.
    func ready() async throws -> NativeThreadSnapshot {
        try await snapshot("the agent to bootstrap") { !$0.piSessionID.isEmpty && !$0.messages.isEmpty }
    }

    func send(_ text: String, delivery: NativeThreadDelivery = .followUp, images: [NativeImage]? = nil,
              operationID: UUID = UUID(), from s: NativeThreadSnapshot) async throws -> NativeThreadResult {
        try await request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: operationID,
                                text: text, delivery: delivery, images: images))
    }

    /// Every record the stub read from stdin, in order.
    func stdin(_ type: String? = nil) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            .filter { type == nil || $0["type"] as? String == type }
    }

    /// The `count`-th stdin record of `type`, once the stub has read it.
    func waitForStdin(_ type: String, count: Int = 1) async throws -> [String: Any] {
        try await eventually("stdin record \(count) of \(type)") { stdin(type).count >= count }
        return stdin(type)[count - 1]
    }

    /// Releases one of the stub's "slow" turn pauses.
    func release(_ pause: Int) {
        FileManager.default.createFile(atPath: host.dir.appendingPathComponent("continue-\(pause)").path, contents: nil)
    }

    /// Lets the stub's `k`-th tool call (of a "tools:N" run) finish.
    func finishTool(_ k: Int) {
        FileManager.default.createFile(atPath: host.dir.appendingPathComponent("tool-\(k)").path, contents: nil)
    }

    /// Lets a "hold-settle" run settle.
    func releaseSettle() {
        FileManager.default.createFile(atPath: host.dir.appendingPathComponent("settle").path, contents: nil)
    }

    func queue(_ action: NativeQueueAction, operationID: UUID = UUID(), from s: NativeThreadSnapshot) async throws -> NativeThreadResult {
        try await request(.queue(expectedSessionID: s.piSessionID, generation: s.generation, operationID: operationID, action: action))
    }
}

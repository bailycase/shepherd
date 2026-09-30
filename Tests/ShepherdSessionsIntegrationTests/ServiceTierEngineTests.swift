import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A provider that records what reaches the wire (`Tests/Extensions/fake-provider.mjs`), run on
/// the engine's own node.
final class FakeProviderProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    let log: URL
    let port: Int

    init(node: URL, directory: URL) throws {
        log = directory.appendingPathComponent("provider-requests.jsonl")
        let script = EngineSmoke.repository.appendingPathComponent("Tests/Extensions/fake-provider.mjs")
        process.executableURL = node
        process.arguments = [script.path, log.path]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        // The first line it prints is {"port":N}.
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw CommandFailure("the fake provider", "exited before listening") }
            line.append(chunk)
        }
        let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        port = try #require(record?["port"] as? Int)
    }

    /// Every request the provider has answered, in order: path and body.
    var requests: [(path: String, body: [String: Any])] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let path = record["path"] as? String, let body = record["body"] as? [String: Any] else { return nil }
            return (path, body)
        }
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// The whole path, with the pi engine Shepherd ships: a thread's Speed set through the store the
/// composer uses, the host's tier file, the extension inside real pi, and the request body that
/// reaches a fake OpenAI provider. A Standard turn sends no `service_tier`; a Fast one sends
/// `priority`; a relaunch and a pi restarted in place (Retry's start) keep the tier.
///
/// Opt-in like the engine smoke (it needs a staged engine):
///
///     python3 scripts/pi_engine.py stage
///     SHEPHERD_ENGINE_SMOKE=$PWD/.build/pi-engine swift test --filter ServiceTierEngineTests
@Suite("Service tier, through the shipped engine", .integrationTimeLimit,
       .enabled(if: EngineSmoke.engine != nil, "set SHEPHERD_ENGINE_SMOKE to a built Shepherd.app or a staged engine"))
struct ServiceTierEngineTests {
    struct Rig {
        let engine: BundledPiEngine
        let scratch: URL
        let home: PiHome
        let setup: PiSetup
        let project: URL
        let provider: FakeProviderProcess

        init(engine: BundledPiEngine) throws {
            self.engine = engine
            scratch = try makeScratchDirectory("engine-tier")
            let userHome = scratch.appendingPathComponent("home", isDirectory: true)
            project = scratch.appendingPathComponent("project", isDirectory: true)
            for folder in [userHome, project] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            home = PiHome(directory: scratch.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine), userHome: userHome.path)
            setup = PiSetup(engine: .bundled(engine), home: home.directory, userHome: userHome.path)
            try home.install()
            provider = try FakeProviderProcess(node: engine.node, directory: scratch)
            let model = #"{"id":"gpt-6-luna","name":"gpt-6-luna","reasoning":false,"input":["text"],"contextWindow":64000,"maxTokens":1024,"cost":{"input":0.2,"output":0.75,"cacheRead":0,"cacheWrite":0}}"#
            try #"{"providers":{"openai":{"baseUrl":"http://127.0.0.1:\#(provider.port)/v1","apiKey":"fixture-not-secret","api":"openai-responses","models":[\#(model)]}}}"#
                .write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
            try #"{"retry":{"enabled":false},"compaction":{"enabled":false}}"#.write(to: home.settings, atomically: true, encoding: .utf8)
        }

        /// Starts an agent's pi as the app does: a login shell that execs Shepherd's launcher with the
        /// tier extension and the agent's tier file named in its environment.
        func start(_ agent: Agent, tab: ShepherdCore.Tab, pane: LeafPane, on host: ScratchServer) async throws -> SessionID {
            let line = try PiLaunch.agent(home: home, cwd: project.path, sessionID: agent.effectivePiSessionID, model: "openai/gpt-6-luna",
                                          thinking: "off", extensions: [ServiceTierExtension.path(in: home)])
            var env = ServiceTierExtension.environment(for: agent.id, in: home)
            env["SHEPHERD_AGENT_ID"] = agent.id.rawValue
            env["HOME"] = scratch.appendingPathComponent("home").path
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            let session = try await host.server.createSession(params: CreateSessionParams(cwd: project.path, command: line.argv, env: env, runtime: .rpc))
            try await host.server.updatePaneSession(tabID: tab.id, paneID: pane.id, sessionID: session.id)
            return session.id
        }

        func stop() { provider.stop() }
    }

    /// A store fed by the host the way the app's is, so `setServiceTier` is the composer's own call.
    @MainActor
    static func store(for agent: AgentID, on host: ScratchServer) -> (store: NativeThreadStore, task: Task<Void, Never>) {
        let store = NativeThreadStore()
        let server = host.server
        let task = Task { await store.run(request: { try await server.nativeThread(agentID: agent, request: $0) }) }
        return (store, task)
    }

    static func stopped(_ server: SessionServer, _ id: SessionID) async throws {
        try await eventually("the pi to stop") { await server.sessionInfo(sessionID: id)?.isAlive != true }
    }

    /// Sends a prompt through the store and waits for the provider to have answered it.
    @MainActor
    static func turn(_ store: NativeThreadStore, _ text: String, rig: Rig, expecting count: Int) async throws {
        await store.send(text: text)
        try await eventuallyOnMain("the provider to have \(count) requests") { rig.provider.requests.count >= count }
        try await eventuallyOnMain("the turn to settle") { !store.running }
    }

    @Test @MainActor func fastAndStandardReachTheWireAndSurviveARelaunchAndARestartedPi() async throws {
        let engine = try #require(EngineSmoke.engine)
        let rig = try Rig(engine: engine)
        defer { rig.stop() }
        var host = try ScratchServer(pi: rig.setup)
        defer { host.stop() }

        let space = Space(name: "tier", path: rig.project.path)
        try await host.server.addSpace(space)
        let pane = LeafPane(cwd: rig.project.path)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "tier", spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true)
        try await host.server.addAgent(agent, withTab: tab)
        var session = try await rig.start(agent, tab: tab, pane: pane, on: host)

        var (store, task) = Self.store(for: agent.id, on: host)
        defer { task.cancel() }
        try await eventuallyOnMain("the thread to offer a speed", timeout: .seconds(60)) { store.ready && store.offersServiceTier }
        #expect(store.serviceTiers == [.standard, .fast] && store.serviceTier == .standard)

        // Standard: nothing in the body.
        try await Self.turn(store, "one", rig: rig, expecting: 1)
        #expect(rig.provider.requests[0].path == "/v1/responses")
        #expect(rig.provider.requests[0].body["service_tier"] == nil, "Standard sends no field")

        // Fast, through the composer's own call: the next request carries it.
        await store.setServiceTier(.fast)
        try await eventuallyOnMain("the thread to say Fast") { store.serviceTier == .fast }
        try await Self.turn(store, "two", rig: rig, expecting: 2)
        #expect(rig.provider.requests[1].body["service_tier"] as? String == "priority")
        #expect(ServiceTierFile.read(for: agent.id, in: host.server.pi.files) == .fast)

        // And back: gone again.
        await store.setServiceTier(.standard)
        try await eventuallyOnMain("the thread to say Standard") { store.serviceTier == .standard }
        try await Self.turn(store, "three", rig: rig, expecting: 3)
        #expect(rig.provider.requests[2].body["service_tier"] == nil)

        // Fast again, then the pi stops and Retry's start brings a new one up in place.
        await store.setServiceTier(.fast)
        try await eventuallyOnMain("the thread to say Fast again") { store.serviceTier == .fast }
        task.cancel()
        let current = host, stopping = session
        current.server.killSession(stopping)
        try await Self.stopped(current.server, stopping)
        await host.server.retireSession(sessionID: session)
        session = try await rig.start(agent, tab: tab, pane: pane, on: host)
        (store, task) = Self.store(for: agent.id, on: host)
        try await eventuallyOnMain("the new pi to serve", timeout: .seconds(60)) { store.ready && store.offersServiceTier }
        #expect(store.serviceTier == .fast, "the restarted pi's thread is still on Fast")
        try await Self.turn(store, "four", rig: rig, expecting: 4)
        #expect(rig.provider.requests[3].body["service_tier"] as? String == "priority", "a pi started by Retry keeps the tier")

        // A relaunch of Shepherd: state.json holds it, the file is written again before pi starts.
        task.cancel()
        let dir = host.dir
        host.stop(keepFiles: true)
        ServiceTierFile.remove(for: agent.id, in: rig.home)
        host = try ScratchServer(dir: dir, pi: rig.setup)
        let restored = try #require(host.server.state.agents.first { $0.id == agent.id })
        #expect(restored.serviceTier == .fast)
        session = try await rig.start(restored, tab: tab, pane: pane, on: host)
        (store, task) = Self.store(for: agent.id, on: host)
        try await eventuallyOnMain("the relaunched pi to serve", timeout: .seconds(60)) { store.ready && store.offersServiceTier }
        try await Self.turn(store, "five", rig: rig, expecting: 5)
        #expect(rig.provider.requests[4].body["service_tier"] as? String == "priority", "a relaunched agent asks for Fast")
        task.cancel()
    }

    @Test @MainActor func aModelThatTakesNoTierNeverGetsOneWhateverTheAgentsTierIs() async throws {
        let engine = try #require(EngineSmoke.engine)
        let rig = try Rig(engine: engine)
        defer { rig.stop() }
        let host = try ScratchServer(pi: rig.setup)
        defer { host.stop() }
        // The same provider, under a name the table does not list.
        let model = #"{"id":"gpt-6-luna","name":"gpt-6-luna","reasoning":false,"input":["text"],"contextWindow":64000,"maxTokens":1024,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}"#
        try #"{"providers":{"fixture":{"baseUrl":"http://127.0.0.1:\#(rig.provider.port)/v1","apiKey":"fixture-not-secret","api":"openai-responses","models":[\#(model)]}}}"#
            .write(to: rig.home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)

        let space = Space(name: "tier", path: rig.project.path)
        try await host.server.addSpace(space)
        let pane = LeafPane(cwd: rig.project.path)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "tier", spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true, serviceTier: .fast)
        try await host.server.addAgent(agent, withTab: tab)
        let line = try PiLaunch.agent(home: rig.home, cwd: rig.project.path, sessionID: agent.effectivePiSessionID, model: "fixture/gpt-6-luna",
                                      thinking: "off", extensions: [ServiceTierExtension.path(in: rig.home)])
        var env = ServiceTierExtension.environment(for: agent.id, in: rig.home)
        env["SHEPHERD_AGENT_ID"] = agent.id.rawValue
        env["HOME"] = rig.scratch.appendingPathComponent("home").path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let info = try await host.server.createSession(params: CreateSessionParams(cwd: rig.project.path, command: line.argv, env: env, runtime: .rpc))
        try await host.server.updatePaneSession(tabID: tab.id, paneID: pane.id, sessionID: info.id)

        let (store, task) = Self.store(for: agent.id, on: host)
        defer { task.cancel() }
        try await eventuallyOnMain("the thread to serve", timeout: .seconds(60)) { store.ready && store.model == "fixture/gpt-6-luna" }
        #expect(!store.offersServiceTier && store.serviceTier == .fast, "no control, and the agent's Fast is inert")
        try await Self.turn(store, "hello", rig: rig, expecting: 1)
        #expect(rig.provider.requests[0].body["service_tier"] == nil)
        #expect(ServiceTierFile.read(for: agent.id, in: rig.home) == .fast, "the file says Fast; the extension still never adds it")
    }
}

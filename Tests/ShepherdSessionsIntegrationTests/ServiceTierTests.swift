import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A thread's service tier (the composer's Speed control) on the host: kept per agent and on disk,
/// written to the file its pi reads on every request, changed through the thread's own request,
/// and shown in its snapshot. The stub pi logs what that file holds when it starts and before each
/// prompt, which is what the real extension reads before each model call (the node test
/// `Tests/Extensions/service-tier.test.mjs` runs real pi on that file).
@Suite("Service tier", .integrationTimeLimit)
struct ServiceTierTests {
    static let openAI = #"{"provider":"openai","id":"gpt-6-luna","api":"openai-responses"}"#
    static let apis = #"{"openai/gpt-6-luna":"openai-responses","openai-codex/gpt-6-sol":"openai-codex-responses","cliproxyapi/gpt-6-sol":"openai-responses","cliproxyapi/claude-opus-5":"openai-completions"}"#

    /// An agent started the way the app starts one: in state first, then its pi, with the tier
    /// file named in its environment, then bound to its pane.
    static func agent(on h: ScratchServer, tier: ServiceTier = .standard, model: String? = openAI) async throws -> (pi: PiAgent, tab: Tab, pane: LeafPane) {
        let space = h.server.state.spaces.first ?? Space(name: "rpc", path: h.dir.path)
        if h.server.state.spaces.isEmpty { try await h.server.addSpace(space) }
        let pane = LeafPane(cwd: h.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "rpc", spaceID: space.id, tabID: tab.id, paneID: pane.id, serviceTier: tier)
        try await h.server.addAgent(agent, withTab: tab)
        let pi = try await start(agent, tab: tab, pane: pane, on: h, model: model)
        return (pi, tab, pane)
    }

    /// Starts (or starts again) an agent's pi: what launch, relaunch and Retry all do.
    static func start(_ agent: Agent, tab: Tab, pane: LeafPane, on h: ScratchServer, model: String? = openAI) async throws -> PiAgent {
        let log = h.dir.appendingPathComponent("stdin-\(UUID().uuidString.prefix(6)).log")
        var env = ServiceTierExtension.environment(for: agent.id, in: h.server.pi.files)
        env["SHEPHERD_AGENT_ID"] = agent.id.rawValue
        env["STUB_PI_LOG"] = log.path
        env["STUB_PI_MODEL_APIS"] = apis
        if let model { env["STUB_PI_MODEL"] = model }
        let session = try await h.server.createSession(params: CreateSessionParams(
            cwd: h.dir.path, command: StubPi.command, env: env, runtime: .rpc))
        try await h.server.updatePaneSession(tabID: tab.id, paneID: pane.id, sessionID: session.id)
        return PiAgent(host: h, agent: agent, sessionID: session.id, log: log)
    }

    /// The tier file's text a pi read: at its start, or before its `n`-th prompt.
    static func read(_ pi: PiAgent, when: String, _ n: Int = 1) async throws -> String? {
        try await eventually("the stub's \(when) read of the tier file") { pi.stdin("stub-service-tier").filter { $0["when"] as? String == when }.count >= n }
        return pi.stdin("stub-service-tier").filter { $0["when"] as? String == when }[n - 1]["content"] as? String
    }

    static func persistedTier(_ h: ScratchServer) throws -> String? {
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: h.stateURL)) as? [String: Any])
        let agents = try #require(root["agents"] as? [[String: Any]])
        return agents.first?["serviceTier"] as? String
    }

    func setTier(_ pi: PiAgent, _ tier: String, from s: NativeThreadSnapshot) async throws -> NativeThreadResult {
        try await pi.request(.setServiceTier(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), tier: tier))
    }

    // MARK: The file, before pi starts

    @Test(arguments: [ServiceTier.standard, .fast])
    func anAgentsTierFileIsWrittenBeforeItsPiStartsAndPiReadsItBeforeEachPrompt(tier: ServiceTier) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, _, _) = try await Self.agent(on: h, tier: tier)
        #expect(try await Self.read(pi, when: "start") == #"{"tier":"\#(tier.rawValue)"}"#, "there before pi's first line ran")
        let ready = try await pi.ready()
        _ = try await pi.send("hello", from: ready)
        #expect(try await Self.read(pi, when: "prompt") == #"{"tier":"\#(tier.rawValue)"}"#)
    }

    @Test func aPiNotStartedForAnAgentGetsNoFile() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        #expect(pi.stdin("stub-service-tier").isEmpty)
        let file = try #require(ServiceTierFile.url(for: pi.agent.id, in: h.server.pi.files))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Changing it

    @Test func theThreadsRequestChangesTheFileTheStateTheSnapshotAndEveryBroadcast() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, _, _) = try await Self.agent(on: h)
        let ready = try await pi.ready()
        #expect(ready.serviceTier == "standard" && ready.serviceTiers == ["standard", "fast"])
        #expect(ready.supportedActions.contains("setServiceTier"))
        #expect(try Self.persistedTier(h) == nil, "Standard writes no key")

        let fast = try await setTier(pi, "fast", from: ready)
        #expect(fast.acceptedID != nil, "\(fast)")
        let changed = try await pi.snapshot("the snapshot to show Fast") { $0.serviceTier == "fast" }
        #expect(changed.revision > ready.revision, "clients pull a new snapshot")
        #expect(changed.serviceTiers == ["standard", "fast"])
        #expect(h.server.state.agents.first?.serviceTier == .fast)
        #expect(try Self.persistedTier(h) == "fast", "it survives a relaunch: state.json holds it")
        #expect(ServiceTierFile.read(for: pi.agent.id, in: h.server.pi.files) == .fast)
        #expect(h.broadcasts.current.contains { $0.agents.first?.serviceTier == .fast }, "remote clients are told through the state")

        // The next prompt sees it, running or not; and back again.
        _ = try await pi.send("one", from: changed)
        #expect(try await Self.read(pi, when: "prompt", 1) == #"{"tier":"fast"}"#)
        let settled = try await pi.snapshot("the turn to settle") { !$0.running && $0.messages.count > 2 }
        #expect(try await setTier(pi, "standard", from: settled).acceptedID != nil)
        _ = try await pi.snapshot("Standard") { $0.serviceTier == "standard" }
        let again = try await pi.snapshot { !$0.running }
        _ = try await pi.send("two", from: again)
        #expect(try await Self.read(pi, when: "prompt", 2) == #"{"tier":"standard"}"#)
        #expect(try Self.persistedTier(h) == nil)
    }

    @Test func theSameTierAgainChangesNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, _, _) = try await Self.agent(on: h, tier: .fast)
        let ready = try await pi.ready()
        let before = h.broadcasts.current.count
        #expect(try await setTier(pi, "fast", from: ready).acceptedID != nil)
        #expect(h.broadcasts.current.count == before, "no state broadcast for no change")
        #expect(try Self.persistedTier(h) == "fast")
    }

    @Test func aChangeWhileTheAgentWorksAppliesToItsNextCall() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, _, _) = try await Self.agent(on: h)
        let ready = try await pi.ready()
        _ = try await pi.send("slow", from: ready)
        let running = try await pi.snapshot("the turn to run") { $0.running }
        #expect(try await setTier(pi, "fast", from: running).acceptedID != nil, "no need to wait for the turn to end")
        #expect(ServiceTierFile.read(for: pi.agent.id, in: h.server.pi.files) == .fast)
        pi.release(1)
        pi.release(2)
    }

    @Test func aModelWithNoTierShowsNoSpeedAndRefusesTheRequest() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, _, _) = try await Self.agent(on: h, model: nil)
        let ready = try await pi.ready()
        #expect(ready.model == "anthropic/claude-sonnet-4-20250514" && ready.serviceTiers == [])
        let refused = try await setTier(pi, "fast", from: ready)
        #expect(refused.failureCode == "unsupported", "\(refused)")
        #expect(h.server.state.agents.first?.serviceTier == .standard)
        #expect(try await setTier(pi, "ultrafast", from: ready).failureCode == "invalid")
        #expect(ServiceTierFile.read(for: pi.agent.id, in: h.server.pi.files) == .standard)
        let stale = try await pi.request(.setServiceTier(expectedSessionID: "other", generation: ready.generation, operationID: UUID(), tier: "fast"))
        #expect(stale.failureCode == "stale_session")
    }

    @Test func whatIsOfferedFollowsTheModel() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, _, _) = try await Self.agent(on: h, tier: .fast, model: nil)
        let ready = try await pi.ready()
        #expect(ready.serviceTiers == [] && ready.serviceTier == "fast", "a thread keeps its tier under a model that ignores it")
        for (model, tiers) in [("openai/gpt-6-luna", ["standard", "fast"]), ("openai-codex/gpt-6-sol", ["standard", "fast"]),
                               ("cliproxyapi/claude-opus-5", []), ("anthropic/claude-sonnet-4-20250514", [])] as [(String, [String])] {
            let current = try await pi.snapshot { !$0.piSessionID.isEmpty }
            _ = try await pi.request(.setModel(expectedSessionID: current.piSessionID, generation: current.generation, operationID: UUID(), model: model))
            let next = try await pi.snapshot("\(model) to be the model") { $0.model == model }
            #expect(next.serviceTiers == tiers, "\(model)")
            #expect(next.serviceTier == "fast")
        }
    }

    @Test func aCLIProxyAPIModelIsOfferedByItsOwner() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        // The connection file Settings keeps in the pi home: who owns each model it serves.
        let connection = h.server.pi.home.appendingPathComponent(CLIProxyAPIStore.fileName)
        try FileManager.default.createDirectory(at: h.server.pi.home, withIntermediateDirectories: true)
        try Data(#"{"enabled":true,"baseURL":"http://127.0.0.1:1/v1","apiKey":"k","updatedAt":1,"models":[{"id":"gpt-6-sol","owned_by":"openai"},{"id":"claude-opus-5","owned_by":"anthropic"}]}"#.utf8)
            .write(to: connection)
        let (pi, _, _) = try await Self.agent(on: h, model: #"{"provider":"cliproxyapi","id":"gpt-6-sol","api":"openai-responses"}"#)
        let ready = try await pi.ready()
        #expect(ready.serviceTiers == ["standard", "fast"], "owned by openai")
        // The same id under another owner is not OpenAI's: the listing is what says.
        try Data(#"{"enabled":true,"baseURL":"http://127.0.0.1:1/v1","apiKey":"k","updatedAt":2,"models":[{"id":"gpt-6-sol","owned_by":"antigravity"}]}"#.utf8)
            .write(to: connection)
        _ = try await pi.request(.setModel(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID(), model: "openai/gpt-6-luna"))
        _ = try await pi.snapshot { $0.model == "openai/gpt-6-luna" }
        let again = try await pi.snapshot { !$0.piSessionID.isEmpty }
        _ = try await pi.request(.setModel(expectedSessionID: again.piSessionID, generation: again.generation, operationID: UUID(), model: "cliproxyapi/gpt-6-sol"))
        let other = try await pi.snapshot("the proxy model again") { $0.model == "cliproxyapi/gpt-6-sol" }
        #expect(other.serviceTiers == [], "now owned by antigravity")
    }

    // MARK: Relaunch, Retry, and an agent with no pi

    @Test func aRelaunchedAgentsPiGetsItsTierBackEvenIfTheFileIsGone() async throws {
        let first = try ScratchServer.fresh()
        let (pi, _, _) = try await Self.agent(on: first, tier: .fast)
        _ = try await pi.ready()
        let agent = pi.agent
        let home = first.server.pi.files
        first.stop(keepFiles: true)
        ServiceTierFile.remove(for: agent.id, in: home)
        #expect(ServiceTierFile.read(for: agent.id, in: home) == .standard, "the file is gone with the old run")

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        let restored = try #require(h.server.state.agents.first { $0.id == agent.id })
        #expect(restored.serviceTier == .fast, "state.json kept it")
        let tab = try #require(h.server.state.tabs.first { $0.id == restored.tabID })
        let pane = try #require(tab.layout.leaves.first)
        let relaunched = try await Self.start(restored, tab: tab, pane: pane, on: h)
        #expect(try await Self.read(relaunched, when: "start") == #"{"tier":"fast"}"#)
        let ready = try await relaunched.ready()
        #expect(ready.serviceTier == "fast")
    }

    @Test func aRetryStartedPiKeepsTheTierAndOneChangedWhileItWasDownIsTheNewOne() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, tab, pane) = try await Self.agent(on: h, tier: .fast)
        _ = try await pi.ready()
        // pi stops before it serves again (what Retry answers): the agent stays, its pi does not.
        h.server.killSession(pi.sessionID)
        try await eventually("the old pi to stop") { await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive != true }
        await h.server.retireSession(sessionID: pi.sessionID)

        let again = try await Self.start(pi.agent, tab: tab, pane: pane, on: h)
        #expect(try await Self.read(again, when: "start") == #"{"tier":"fast"}"#, "the restarted pi starts on the agent's tier")

        h.server.killSession(again.sessionID)
        try await eventually("the second pi to stop") { await h.server.sessionInfo(sessionID: again.sessionID)?.isAlive != true }
        await h.server.retireSession(sessionID: again.sessionID)
        try await h.server.setServiceTier(.standard, for: pi.agent.id)
        #expect(ServiceTierFile.read(for: pi.agent.id, in: h.server.pi.files) == .standard, "changed with no pi running")
        let third = try await Self.start(pi.agent, tab: tab, pane: pane, on: h)
        #expect(try await Self.read(third, when: "start") == #"{"tier":"standard"}"#)
        let ready = try await third.ready()
        #expect(ready.serviceTier == "standard")
    }

    @Test func anAgentsFileGoesWithTheAgentAndAnUnknownAgentIsRefused() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (pi, _, _) = try await Self.agent(on: h, tier: .fast)
        _ = try await pi.ready()
        let file = try #require(ServiceTierFile.url(for: pi.agent.id, in: h.server.pi.files))
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await h.server.deleteAgent(pi.agent.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: SessionServerError.self) { try await h.server.setServiceTier(.fast, for: pi.agent.id) }
    }
}

private extension NativeThreadResult {
    var acceptedID: UUID? {
        if case .accepted(let id) = self { return id }
        return nil
    }
}

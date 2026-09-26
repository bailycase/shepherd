import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A pi that stops before it serves keeps its agent (DESIGN.md › Thread › Can't start), through
/// the real view model and the stub pi launched the way the app launches pi: the pane stays with
/// its thread, which says why, the sidebar row reads "can't start", and Retry starts pi again.
@Suite("Agent start problems", .mainActorExclusive)
@MainActor
struct AgentStartProblemTests {
    /// Makes every stub pi started in `dir` from now on start as `config` says (`stub-pi.py`).
    private static func configurePi(in dir: URL, _ config: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("stub-pi-startup.json"))
    }

    private static func healPi(in dir: URL) throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent("stub-pi-startup.json"))
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

    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let config: [String: String]
        let kind: NativeStartProblem.Kind
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "not signed in", config: [
            "exit": "1",
            "stderr": "\u{1B}[31mNo models available. Use /login to log into a provider via OAuth or API key. See:\n  /pi/docs/providers.md\u{1B}[39m",
        ], kind: .notSignedIn),
        Case(name: "an extension failed to load", config: [
            "exit": "1",
            "stderr": "\u{1B}[31mError: Failed to load extension \"/x/broken.ts\": SyntaxError: Unexpected token\u{1B}[39m\n\u{1B}[33mHint: Start without extensions using \"pi -ne\".\u{1B}[39m",
        ], kind: .extensionFailed),
        // pi goes on after its warning: Shepherd stops it.
        Case(name: "creating a new session in place of the one it resumes", config: ["newSession": "1"], kind: .resumedAsNew),
    ]

    /// A restored agent whose pi stops while it starts keeps its pane, its history from disk and
    /// its place, says why, and comes up on Retry once pi can start.
    @Test(arguments: cases)
    func aRestoredAgentWhosePiCannotStartWaitsWithItsReasonUntilRetry(_ c: Case) async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.configurePi(in: app.dir, c.config)
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
        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)

        try await eventuallyOnMain("the thread to say why pi stopped", timeout: .seconds(20)) { store.startProblem != nil }
        #expect(store.startProblem?.kind == c.kind)
        #expect(store.startProblem?.lines.isEmpty == false)
        #expect(pane.phase == .stopped)
        #expect(vm.cannotStart.contains(id))
        #expect(!store.ready && !store.starting && !store.awaitingPi && !store.acceptsSend && store.loadError == nil)
        #expect(store.previewing && store.messages.map(\.entryID) == ["user:1733234567890", "assistant:1733234567891"],
                "the thread keeps its history from disk")
        #expect(vm.state.agents.contains { $0.id == id } && server.state.agents.contains { $0.id == id })
        let row = try #require(vm.sidebarLists.recents.first { $0.id == .local(id) })
        #expect(row.leading == .dot(.failed) && row.accessory == .text("can't start", tone: .failed))
        // A stopped agent's pane never starts pi again on its own.
        #expect(vm.sessions.session(for: agent.piPane, in: agent.tab) === pane)

        try Self.healPi(in: app.dir)
        vm.retryAgentStart(id)
        #expect(store.startProblem == nil && store.starting, "Retry takes the banner away at once")
        #expect(!vm.cannotStart.contains(id))
        try await eventuallyOnMain("pi to serve after Retry", timeout: .seconds(20)) { store.ready }
        #expect(pane.phase == .live && store.startProblem == nil)
        #expect(store.messages.map(\.entryID) == ["user:1733234567890", "assistant:1733234567891"])
    }

    /// A new agent whose pi can't reach a model keeps its opening prompt, which pi never read:
    /// Retry sends it to the pi that starts.
    @Test func aNewAgentsOpeningPromptGoesToThePiRetryStarts() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.configurePi(in: app.dir, ["exit": "1", "stderr": "No models available."])
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        var config = ShepherdViewModel.quickAgentConfig(for: space, defaults: app.settings.agentDefaults)
        config.initialPrompt = "Fix the login redirect"
        let id = try await vm.startAgent(config, selectAfter: false)
        let store = vm.threadStores.store(for: id)
        let server = app.server
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }

        try await eventuallyOnMain("the thread to say why pi stopped", timeout: .seconds(20)) { store.startProblem?.kind == .notSignedIn }
        #expect(vm.state.agents.contains { $0.id == id })

        try Self.healPi(in: app.dir)
        vm.retryAgentStart(id)
        try await eventuallyOnMain("the opening prompt to reach the new pi", timeout: .seconds(20)) {
            store.ready && store.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "Fix the login redirect" } }
        }
    }

    /// pi keeps not finding the conversation: Retry stops it again, and Start new conversation
    /// lets it start one, as pi would on its own.
    @Test func startNewConversationLetsAPiThatCannotFindItsConversationStart() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        try Self.configurePi(in: app.dir, ["newSession": "1"])
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("worker", in: space, piSession: SessionID())
        try Self.writeStubHistory(sessionID: agent.agent.effectivePiSessionID, cwd: space.path, sessionsRoot: app.server.pi.sessionsRoot)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)

        try await eventuallyOnMain("pi to be stopped", timeout: .seconds(20)) { store.startProblem?.kind == .resumedAsNew }
        vm.retryAgentStart(id)
        try await eventuallyOnMain("Retry to meet the same problem", timeout: .seconds(20)) {
            store.startProblem?.kind == .resumedAsNew && pane.phase == .stopped
        }
        vm.retryAgentStart(id, newConversation: true)
        try await eventuallyOnMain("pi to serve its new conversation", timeout: .seconds(20)) { store.ready }
        #expect(store.startProblem == nil && !vm.cannotStart.contains(id) && pane.phase == .live)
    }
}

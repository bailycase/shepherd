import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The thread's projection of the engine Shepherd ships, run for real: the real `SessionServer`
/// starts the staged engine through Shepherd's own launcher, in a scratch pi home, against a
/// scripted provider on the loopback (`Tests/Extensions/engine-provider.mjs`), so every record the
/// thread reads is one the real pi wrote. The stub pi that the other integration suites use
/// models a version of pi; this is what checks the model still holds when the pin changes.
/// Opt-in like `EngineSmokeTests`, for the same reason:
///
///     python3 scripts/pi_engine.py stage
///     SHEPHERD_ENGINE_SMOKE=.build/pi-engine swift test --filter EngineThreadTests
@Suite("The bundled pi engine, through the thread", .integrationTimeLimit,
       .enabled(if: EngineSmoke.engine != nil, "set SHEPHERD_ENGINE_SMOKE to a built Shepherd.app or a staged engine"))
struct EngineThreadTests {
    /// A turn, a tool call and a reasoning block, and what the thread offers as commands: pi's
    /// skills and prompt templates and an extension's command, never the built-ins Shepherd's
    /// pi turns off or the terminal-only ones.
    @Test func turnsToolCallsAndTheCommandMenuProjectFromTheRealEngine() async throws {
        let engine = try #require(EngineSmoke.engine)
        let pi = try await RealPi.launch(engine: engine)
        defer { pi.stop() }
        let ready = try await pi.ready()
        let names = ready.commands?.map(\.name) ?? []
        #expect(Set(names).isSuperset(of: ["greet", "skill:hello", "probe-cmd"]), "pi's templates, skills and extension commands: \(names)")
        #expect(Set(names).isDisjoint(with: ["mcp", "llama", "shepherd-retry"]), "built-ins Shepherd turns off or can't run, and its own: \(names)")
        #expect(ready.thinkingLevels != nil && ready.model == "fixture/fixture", "state and thinking levels from pi: \(String(describing: ready.model))")

        _ = try await pi.send("hello", from: ready)
        let first = try await pi.settled("the first reply") { $0.messages.contains { $0.role == "assistant" } }
        #expect(first.messages.contains { $0.role == "user" && $0.blocks.first?.text == "hello" })
        #expect(first.messages.last?.role == "assistant" && first.messages.last?.blocks.first?.text == "ok")
        #expect(first.provisional.isEmpty)

        _ = try await pi.send("tool please", from: first)
        let tool = try await pi.settled("the tool turn") { $0.messages.last?.blocks.first?.text == "tool done" }
        let call = try #require(tool.messages.first { $0.toolName == "bash" }, "the bash call is a row: \(tool.messages.map(\.role))")
        #expect(call.blocks.map(\.text).joined().contains("hi"), "its result is the command's output")
        #expect(call.isError != true && call.argumentsText?.contains("echo hi") == true, "\(call)")
        #expect(call.status != "running", "the finished call is not running")

        _ = try await pi.send("think about it", from: tool)
        let thought = try await pi.settled("the reasoning turn") { $0.messages.last?.blocks.contains { $0.text == "thought about it" } == true }
        #expect(thought.messages.last?.blocks.contains { $0.kind == .thinking && $0.text == "weighing it" } == true,
                "pi's reasoning block is a thinking block: \(String(describing: thought.messages.last))")
        try await eventually("the context figures to land") { try await pi.request(.snapshot()).snapshotValue?.stats?.contextTokens != nil }
    }

    /// Stop on a streaming turn and a message queued behind it: the partial reply is kept as
    /// stopped, the host keeps the queue, and the thread takes the next turn.
    @Test func stoppingAStreamingTurnKeepsItsPartialReplyAndTheQueue() async throws {
        let engine = try #require(EngineSmoke.engine)
        let pi = try await RealPi.launch(engine: engine)
        defer { pi.stop() }
        let ready = try await pi.ready()
        _ = try await pi.send("slow please", from: ready)
        let streaming = try await pi.snapshot("the reply streaming") { s in
            s.running && s.provisional.contains { $0.role == "assistant" && $0.blocks.first?.text.contains("word1") == true }
        }
        let queuedID = UUID()
        _ = try await pi.send("hello queued", delivery: .followUp, operationID: queuedID, from: streaming)
        let queued = try await pi.snapshot("the follow-up held by the host") { $0.queue?.items.map(\.id) == [queuedID] }
        let stop = NativeThreadRequest.abort(expectedSessionID: queued.piSessionID, generation: queued.generation, operationID: UUID())
        _ = try await pi.request(stop)
        let stopped = try await pi.snapshot("the turn stopped") { !$0.running && $0.provisional.isEmpty }
        let partial = try #require(stopped.messages.last { $0.role == "assistant" })
        #expect(partial.blocks.first?.text.contains("word0") == true, "what streamed before the stop is kept: \(partial)")
        #expect(partial.status == "aborted" || partial.status == "stopped", "and says it was stopped: \(String(describing: partial.status))")
        #expect(stopped.queue?.items.map(\.id) == [queuedID], "the queue is held, not sent to pi: \(String(describing: stopped.queue))")

        // The queue goes when the person sends it (or the next message), and the thread runs on.
        _ = try await pi.send("hello again", from: stopped)
        let after = try await pi.settled("the next turn") { $0.messages.contains { $0.blocks.first?.text == "hello again" } }
        #expect(after.messages.last?.blocks.first?.text == "ok")
    }

    /// An extension's dialog is a question in the thread, answered over the same channel; a
    /// command's `notify` is a note where the person is looking, and a prompt template and a skill
    /// run as turns.
    @Test func dialogsCommandNoticesTemplatesAndSkillsWorkOnTheRealEngine() async throws {
        let engine = try #require(EngineSmoke.engine)
        let pi = try await RealPi.launch(engine: engine)
        defer { pi.stop() }
        let ready = try await pi.ready()
        // pi answers a command's prompt when its handler returns, which is when the question is
        // answered, so the send is still out while the thread shows the question.
        async let asked = pi.send("/ask-me", from: ready)
        let asking = try await pi.snapshot("pi's question") { !$0.dialogs.isEmpty }
        let dialog = try #require(asking.dialogs.first)
        #expect(dialog.kind == .select && dialog.title == "Pick one" && dialog.options == ["alpha", "beta"], "\(dialog)")
        _ = try await pi.request(.answer(expectedSessionID: asking.piSessionID, generation: asking.generation, operationID: UUID(),
                                         dialogID: dialog.id, answer: .select(value: "beta")))
        let answered = try await pi.snapshot("the answer's note") { s in
            s.dialogs.isEmpty && (s.messages + s.provisional).contains { $0.blocks.contains { $0.text == "picked:beta" } }
        }
        #expect(!answered.running)
        _ = try await asked

        _ = try await pi.send("/probe-cmd x", from: answered)
        let note = try await pi.snapshot("the command's note") { s in
            (s.messages + s.provisional).contains { $0.blocks.contains { $0.text == "probed:x" } }
        }

        _ = try await pi.send("/greet Ada", from: note)
        let greeted = try await pi.settled("the template's turn") { $0.messages.contains { $0.role == "assistant" } }
        #expect(greeted.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text.contains("Ada") } }, "\(greeted.messages.map(\.role))")

        let count = greeted.messages.filter { $0.role == "assistant" }.count
        _ = try await pi.send("/skill:hello now", from: greeted)
        let skilled = try await pi.settled("the skill's turn") { $0.messages.filter { $0.role == "assistant" }.count == count + 1 }
        #expect(skilled.messages.last?.blocks.first?.text == "ok")
    }

    /// Compact now: pi summarizes through the provider and the thread shows what was kept.
    @Test func compactingSummarizesThroughTheRealEngineAndShowsWhatWasKept() async throws {
        let engine = try #require(EngineSmoke.engine)
        let pi = try await RealPi.launch(engine: engine)
        defer { pi.stop() }
        var latest = try await pi.ready()
        for text in ["hello", "hello again", "and once more"] {
            _ = try await pi.send(text, from: latest)
            latest = try await pi.settled("the reply to \(text)") { $0.messages.last?.role == "assistant" && $0.messages.contains { $0.blocks.first?.text == text } }
        }
        _ = try await pi.request(.compact(expectedSessionID: latest.piSessionID, generation: latest.generation, operationID: UUID()))
        let compacted = try await pi.snapshot("the compaction") { s in
            !s.running && s.messages.contains { $0.role == "compactionSummary" }
        }
        let summary = try #require(compacted.messages.first { $0.role == "compactionSummary" })
        let run = try #require(summary.compaction, "\(summary)")
        #expect(run.phase == .done && run.reason == .manual && run.summary?.contains("the conversation so far") == true, "\(run)")
        #expect((run.tokensBefore ?? 0) > 0, "pi reports what the context held before: \(run)")
        #expect(compacted.context?.summaryEntryID == summary.entryID, "the context points at the summary: \(String(describing: compacted.context))")
    }

    /// What pi writes to the session file reads back as the thread the app showed: the preview a
    /// resumed agent draws before its pi serves (`PiSessionPreview`), over a turn, a tool call and
    /// a reasoning block, and then over a compaction (which, as in pi's own context, leaves what
    /// follows the cut and the summary), from the file the real pi appended to.
    @Test func theSessionFilePiWritesReadsBackAsTheThreadTheAppShowed() async throws {
        let engine = try #require(EngineSmoke.engine)
        let pi = try await RealPi.launch(engine: engine)
        defer { pi.stop() }
        var latest = try await pi.ready()
        for text in ["hello", "tool please", "think about it"] {
            _ = try await pi.send(text, from: latest)
            latest = try await pi.settled("the reply to \(text)") { s in
                s.messages.contains { $0.blocks.first?.text == text } && s.messages.last?.role == "assistant"
            }
        }
        func summary(_ messages: [NativeThreadMessage]) -> [String] {
            messages.map { "\($0.role):\($0.toolName ?? ""):\($0.blocks.map(\.text).joined(separator: "|"))" }
        }
        let before = try #require(PiSessionPreview.snapshot(file: pi.sessionFile, sessionID: pi.sessionID), "the file reads")
        #expect(summary(before.messages) == summary(latest.messages), "the preview and the live thread agree row by row")
        #expect(before.messages.contains { $0.toolName == "bash" && $0.blocks.first?.text == "hi\n" })
        #expect(before.model == "fixture/fixture", "the model pi recorded: \(String(describing: before.model))")

        _ = try await pi.request(.compact(expectedSessionID: latest.piSessionID, generation: latest.generation, operationID: UUID()))
        _ = try await pi.snapshot("the compaction") { s in !s.running && s.messages.contains { $0.role == "compactionSummary" } }
        let after = try #require(PiSessionPreview.snapshot(file: pi.sessionFile, sessionID: pi.sessionID))
        let row = try #require(after.messages.last { $0.role == "compactionSummary" }, "\(summary(after.messages))")
        #expect(row.compaction?.summary?.contains("the conversation so far") == true, "\(String(describing: row.compaction))")
        #expect(after.messages.last?.role == "compactionSummary" && after.messages.contains { $0.blocks.contains { $0.text == "thought about it" } },
                "the kept reply and the summary: \(summary(after.messages))")
    }
}

/// A real pi, started the way the app starts an agent's (`PiLaunch.agent`, through the launcher in
/// a scratch Shepherd home), on a `SessionServer`, against `engine-provider.mjs`.
final class RealPi: @unchecked Sendable {
    let host: ScratchServer
    let agent: PiAgent
    /// The session file the app seeds and pi appends to, and the id pi resumes it by.
    let sessionFile: URL
    let sessionID: String
    private let provider: Process
    private let providerInput: Pipe

    private init(host: ScratchServer, agent: PiAgent, sessionFile: URL, sessionID: String, provider: Process, providerInput: Pipe) {
        self.host = host
        self.agent = agent
        self.sessionFile = sessionFile
        self.sessionID = sessionID
        self.provider = provider
        self.providerInput = providerInput
    }

    /// An extension with a command that asks a question and one that only speaks.
    static let extensionSource = """
        export default function (pi: any): void {
          pi.registerCommand("probe-cmd", { description: "Say what it was given", handler: async (args: string, ctx: any) => {
            ctx.ui.notify("probed:" + args, "info");
          } });
          pi.registerCommand("ask-me", { description: "Ask a question", handler: async (_args: string, ctx: any) => {
            const choice = await ctx.ui.select("Pick one", ["alpha", "beta"]);
            ctx.ui.notify("picked:" + choice, "info");
          } });
        }

        """

    static func launch(engine: BundledPiEngine) async throws -> RealPi {
        let directory = try makeScratchDirectory("real-pi")
        let setup = PiSetup(engine: .bundled(engine), home: directory.appendingPathComponent("support/pi"),
                            userHome: directory.appendingPathComponent("home").path)
        let host = try ScratchServer(dir: directory, pi: setup)
        do {
            let files = FileManager.default
            let userHome = host.dir.appendingPathComponent("home", isDirectory: true)
            let temporary = host.dir.appendingPathComponent("tmp", isDirectory: true)
            let project = host.dir.appendingPathComponent("project", isDirectory: true)
            for folder in [userHome, temporary, project] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }

            let script = EngineSmoke.repository.appendingPathComponent("Tests/Extensions/engine-provider.mjs")
            let provider = Process()
            provider.executableURL = engine.node
            provider.arguments = [script.path]
            let input = Pipe(), output = Pipe()
            provider.standardInput = input
            provider.standardOutput = output
            try provider.run()
            let port = try await readPort(from: output.fileHandleForReading)

            let home = PiHome(directory: host.dir.appendingPathComponent("support/pi", isDirectory: true), engine: .bundled(engine),
                              userHome: userHome.path)
            try home.install()
            let models = """
                {"providers":{"fixture":{"baseUrl":"http://127.0.0.1:\(port)/v1","api":"openai-completions","apiKey":"fixture-key",\
                "models":[{"id":"fixture","name":"fixture","reasoning":true,"input":["text"],"contextWindow":64000,"maxTokens":1024}]}}}
                """
            try models.write(to: home.directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
            var settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.settings)) as? [String: Any])
            settings["compaction"] = ["enabled": true, "keepRecentTokens": 1, "reserveTokens": 10]
            settings["retry"] = ["enabled": false]
            try JSONSerialization.data(withJSONObject: settings).write(to: home.settings)
            try files.createDirectory(at: home.directory.appendingPathComponent("skills/hello"), withIntermediateDirectories: true)
            try "---\nname: hello\ndescription: Says hello\n---\nSay hello.\n"
                .write(to: home.directory.appendingPathComponent("skills/hello/SKILL.md"), atomically: true, encoding: .utf8)
            try files.createDirectory(at: home.directory.appendingPathComponent("prompts"), withIntermediateDirectories: true)
            try "---\ndescription: Greet someone\n---\nGreet $1 warmly.\n"
                .write(to: home.directory.appendingPathComponent("prompts/greet.md"), atomically: true, encoding: .utf8)
            let fixture = host.dir.appendingPathComponent("commands.ts")
            try extensionSource.write(to: fixture, atomically: true, encoding: .utf8)

            // The session header the app seeds before it starts an agent (PiSessionFile.seedIfMissing),
            // so pi opens the session by its id instead of warning that it found none.
            let sessionID = UUID().uuidString.lowercased()
            let folder = home.sessionDirectory(forCwd: project.path)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let header: [String: Any] = ["type": "session", "version": 3, "id": sessionID, "timestamp": "2026-10-01T00:00:00.000Z",
                                         "cwd": PiHome.canonical(project.path)]
            let sessionFile = folder.appendingPathComponent("2026-10-01T00-00-00-000Z_\(sessionID).jsonl")
            try (JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) + Data("\n".utf8)).write(to: sessionFile)
            let line = try PiLaunch.agent(home: home, cwd: project.path, sessionID: sessionID, model: "fixture/fixture", thinking: nil,
                                          extensions: [fixture.path])
            let session = try await host.server.createSession(params: CreateSessionParams(
                cwd: project.path, command: line.argv,
                env: ["HOME": userHome.path, "TMPDIR": temporary.path + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], runtime: .rpc), resuming: sessionID)
            let space = Space(name: "rpc", path: project.path)
            try await host.server.addSpace(space)
            let pane = LeafPane(sessionID: session.id, cwd: project.path)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            let agent = Agent(name: "rpc", spaceID: space.id, tabID: tab.id, paneID: pane.id)
            try await host.server.addAgent(agent, withTab: tab)
            return RealPi(host: host, agent: PiAgent(host: host, agent: agent, sessionID: session.id, log: host.dir.appendingPathComponent("unused.log")),
                          sessionFile: sessionFile, sessionID: sessionID, provider: provider, providerInput: input)
        } catch {
            host.stop()
            throw error
        }
    }

    /// The provider's `{"port":N}` first line.
    private static func readPort(from handle: FileHandle) async throws -> Int {
        let line = Locked(Data())
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            line.withValue { $0.append(chunk) }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        defer { handle.readabilityHandler = nil }
        var port: Int?
        try await eventually("the scripted provider to listen") {
            let data = line.current
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
                  let object = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] else { return false }
            port = object["port"] as? Int
            return port != nil
        }
        return try #require(port)
    }

    func stop() {
        host.stop()
        try? providerInput.fileHandleForWriting.close()
        if provider.isRunning { provider.terminate() }
    }

    func request(_ request: NativeThreadRequest) async throws -> NativeThreadResult { try await agent.request(request) }

    func send(_ text: String, delivery: NativeThreadDelivery = .followUp, operationID: UUID = UUID(), from s: NativeThreadSnapshot) async throws -> NativeThreadResult {
        try await agent.send(text, delivery: delivery, operationID: operationID, from: s)
    }

    func snapshot(_ what: String, where condition: (NativeThreadSnapshot) -> Bool) async throws -> NativeThreadSnapshot {
        try await agent.snapshot(what, timeout: .seconds(60), where: condition)
    }

    /// pi's state, history, stats and commands have all landed.
    func ready() async throws -> NativeThreadSnapshot {
        do {
            return try await snapshot("the bootstrap to land") { s in
                !s.piSessionID.isEmpty && s.stats != nil && s.commands != nil && s.thinkingLevels != nil && s.model != nil
            }
        } catch {
            let s = try? await request(.snapshot()).snapshotValue
            throw CommandFailure("bootstrap", "\(error); session \(s?.piSessionID ?? "nil") stats \(s?.stats != nil) commands \(s?.commands?.count ?? -1) levels \(s?.thinkingLevels ?? []) model \(s?.model ?? "nil") problem \(String(describing: s?.startProblem))")
        }
    }

    /// The first snapshot with pi idle, nothing in flight, and `condition` true.
    func settled(_ what: String, where condition: (NativeThreadSnapshot) -> Bool) async throws -> NativeThreadSnapshot {
        try await snapshot(what) { !$0.running && $0.provisional.isEmpty && condition($0) }
    }
}

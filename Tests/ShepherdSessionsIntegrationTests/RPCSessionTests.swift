import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// `RPCSession`: pi on plain pipes. JSONL framing, request/response correlation, timeouts,
/// and the lifecycle of the child process. Driven against the scripted stub pi.
@Suite("RPC session transport")
struct RPCSessionTests {
    final class Harness: @unchecked Sendable {
        let queue: DispatchQueue
        let session: RPCSession
        let dir: URL
        let events = Locked<[RPCEvent]>([])
        let stderr = Locked<[String]>([])
        let exit = Locked<(done: Bool, code: Int32?)>((false, nil))

        init(command: [String] = StubPi.command, env: [String: String]? = nil) throws {
            dir = try uniqueDirectory("rpc")
            queue = DispatchQueue(label: "test.rpc")
            session = try RPCSession(params: CreateSessionParams(cwd: dir.path, command: command, env: env, runtime: .rpc), queue: queue)
            session.onEvent = { [events] event in events.withValue { $0.append(event) } }
            session.onStderr = { [stderr] line in stderr.withValue { $0.append(line) } }
            session.onExit = { [exit] code in exit.withValue { $0 = (true, code) } }
            session.start()
        }

        func request(_ command: RPCCommand, timeout: TimeInterval = 10) async -> Result<RPCResponse, RPCError> {
            await withCheckedContinuation { continuation in
                queue.async { self.session.request(command, timeout: timeout) { continuation.resume(returning: $0) } }
            }
        }

        func send(_ command: RPCCommand) { queue.async { self.session.send(command) } }

        func types() -> [String] {
            events.current.map { event in
                switch event {
                case .agentStart: "agent_start"
                case .agentEnd: "agent_end"
                case .agentSettled: "agent_settled"
                case .turnStart: "turn_start"
                case .turnEnd: "turn_end"
                case .messageStart: "message_start"
                case .messageUpdate: "message_update"
                case .messageEnd: "message_end"
                case .toolExecutionStart: "tool_execution_start"
                case .toolExecutionUpdate: "tool_execution_update"
                case .toolExecutionEnd: "tool_execution_end"
                case .queueUpdate: "queue_update"
                case .extensionUIRequest: "extension_ui_request"
                case .extensionError: "extension_error"
                case .unknown(let type): "unknown:\(type)"
                }
            }
        }

        func waitFor(_ type: String) async throws {
            try await eventually("the \(type) event") { types().contains(type) }
        }

        func stop() {
            queue.sync { session.shutdown() }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func aRequestIsAnsweredByItsResponse() async throws {
        let h = try Harness()
        defer { h.stop() }
        let response = try await h.request(.getState).get()
        #expect(response.command == "get_state")
        #expect(response.success)
        #expect(response.data?["sessionId"]?.stringValue == "stub-session")
        #expect(response.id?.hasPrefix(h.session.id.rawValue) == true)
    }

    /// Records split on LF only: a U+2028 inside a JSON string is not a line break, CRLF is
    /// tolerated, and unknown event types surface as `.unknown` instead of failing the reader.
    @Test func aStreamingTurnIsFramedOnLineFeedsOnly() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(try await h.request(.prompt(message: "hello")).get().success)
        try await h.waitFor("agent_settled")

        #expect(h.types() == [
            "agent_start", "turn_start", "message_start",
            "message_update", "message_update", "message_update", "message_update", "message_update",
            "message_update", "message_update",
            "message_end", "tool_execution_start", "tool_execution_end", "turn_end",
            "unknown:compaction_start", "agent_end", "agent_settled",
        ])
        var text = ""
        for case .messageUpdate(let delta, let usage) in h.events.current {
            #expect(usage?["totalTokens"]?.doubleValue == 101)
            if delta.type == "text_delta" { text += delta.delta ?? "" }
        }
        #expect(text == "Hello line\u{2028}sep world")
    }

    @Test func overlappingRequestsAreCorrelatedByID() async throws {
        let h = try Harness()
        defer { h.stop() }
        async let messages = h.request(.getMessages)
        async let commands = h.request(.getCommands)
        async let stats = h.request(.getSessionStats)
        let (m, c, s) = try await (messages.get(), commands.get(), stats.get())
        #expect(m.command == "get_messages" && m.data?["messages"]?.arrayValue?.count == 2)
        #expect(c.command == "get_commands" && c.data?["commands"]?.arrayValue?.first?["name"]?.stringValue == "session-name")
        #expect(s.command == "get_session_stats" && s.data?["contextUsage"]?["percent"]?.doubleValue == 30)
        #expect(Set([m.id, c.id, s.id].compactMap { $0 }).count == 3)
    }

    @Test func anUnansweredRequestTimesOutAndTheTransportStaysUsable() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(await h.request(.prompt(message: "hang"), timeout: 0.2) == .failure(.timeout))
        #expect(try await h.request(.getState).get().success)
    }

    @Test func abortIsAnsweredAndEndsTheRun() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(try await h.request(.abort).get().command == "abort")
        try await h.waitFor("agent_settled")
        #expect(h.types() == ["agent_end", "agent_settled"])
    }

    @Test func anExtensionDialogRoundTrips() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(try await h.request(.prompt(message: "ask")).get().success)
        try await h.waitFor("extension_ui_request")
        var request: RPCExtensionUIRequest?
        for case .extensionUIRequest(let r) in h.events.current { request = r }
        let ui = try #require(request)
        #expect(ui.method == "confirm" && ui.id == "uuid-2" && ui.title == "Clear session?" && ui.timeout == 60000)

        h.send(.extensionUIResponse(id: ui.id, confirmed: true))
        try await h.waitFor("agent_settled")
        var answer: [RPCMessage] = []
        for case .agentEnd(let messages, _) in h.events.current { answer = messages }
        #expect(answer.first?.content == [.text("confirmed")])
    }

    @Test func stderrIsForwardedLineByLine() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(try await h.request(.prompt(message: "stderr")).get().success)
        try await eventually("the stderr line") { h.stderr.current.contains("stub-pi: warning line") }
    }

    /// A malformed record is logged and dropped; the next record still arrives.
    @Test func aMalformedRecordDoesNotStopTheReader() async throws {
        let h = try Harness(command: ["/bin/sh", "-c", #"printf 'not json\n{"type":"agent_start"}\n'; sleep 30"#])
        defer { h.stop() }
        try await h.waitFor("agent_start")
        #expect(h.types() == ["agent_start"])
    }

    @Test func theChildEnvironmentIsSanitised() async throws {
        let h = try Harness(command: ["/bin/sh", "-c", #"echo "tmux=${TMUX-unset} extra=$EXTRA" >&2; sleep 30"#],
                            env: ["TMUX": "/tmp/stale", "EXTRA": "passed"])
        defer { h.stop() }
        try await eventually("the environment report") { h.stderr.current == ["tmux=unset extra=passed"] }
    }

    @Test func deathFailsOutstandingRequestsWithTheExitCode() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(await h.request(.prompt(message: "die")) == .failure(.exited(code: 3)))
        try await eventually("the exit callback") { h.exit.current.done }
        #expect(h.exit.current.code == 3)
        #expect(await h.request(.getState) == .failure(.notAlive))
        try await eventually("the dying words on stderr") { h.stderr.current.contains("stub-pi: dying") }
    }

    @Test func killTerminatesWithSIGTERM() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(try await h.request(.getState).get().success)
        h.queue.async { h.session.kill() }
        try await eventually("the exit callback") { h.exit.current.done }
        #expect(h.exit.current.code == nil, "python dies to SIGTERM, so there is no exit code")
    }

    /// App shutdown: requests in flight fail, and no exit callback fires into a torn-down app.
    @Test func shutdownFailsOutstandingRequestsWithoutAnExitCallback() async throws {
        let h = try Harness()
        defer { h.stop() }
        #expect(try await h.request(.getState).get().success)
        let pending = await withCheckedContinuation { continuation in
            h.queue.async {
                h.session.request(.prompt(message: "hang")) { continuation.resume(returning: $0) }
                h.session.shutdown()
            }
        }
        #expect(pending == .failure(.notAlive))
        await withCheckedContinuation { continuation in h.queue.async { continuation.resume() } }
        #expect(!h.exit.current.done)
    }

    @Test func aMissingExecutableFailsToSpawn() {
        #expect(throws: RPCSession.SpawnError.self) {
            _ = try RPCSession(params: CreateSessionParams(cwd: "/", command: ["/nonexistent/pi"], runtime: .rpc),
                               queue: DispatchQueue(label: "test.rpc.missing"))
        }
    }
}

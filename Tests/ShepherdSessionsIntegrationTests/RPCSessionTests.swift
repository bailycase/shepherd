import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// `RPCSession`: pi on plain pipes. JSONL framing, request/response correlation, timeouts,
/// and the lifecycle of the child process. Driven against the scripted stub pi.
@Suite("RPC session transport", .integrationTimeLimit)
struct RPCSessionTests {
    final class Harness: @unchecked Sendable {
        let queue: DispatchQueue
        let session: RPCSession
        let dir: URL
        let events = Locked<[RPCEvent]>([])
        let stderr = Locked<[String]>([])
        let exit = Locked<(done: Bool, code: Int32?)>((false, nil))

        init(command: [String] = StubPi.command, env: [String: String]? = nil) throws {
            dir = try makeScratchDirectory("rpc")
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
            events.current.map(Self.type)
        }

        static func type(_ event: RPCEvent) -> String {
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
            case .compactionStart: "compaction_start"
            case .compactionEnd: "compaction_end"
            case .unknown(let type): "unknown:\(type)"
            }
        }

        /// Runs `body` on the session's queue and returns its result.
        func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
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
            "unknown:stub_unmodelled_event", "agent_end", "agent_settled",
        ])
        var text = ""
        for case .messageUpdate(let delta) in h.events.current where delta.type == "text_delta" {
            text += delta.delta ?? ""
        }
        #expect(text == "Hello line\u{2028}sep world")
    }

    /// A record long enough to decode off the queue keeps its place in line: what pi wrote after
    /// it waits, and the session handles every record in the order pi wrote them.
    @Test func recordsAfterALargeResponseAreHandledAfterItInOrder() async throws {
        let h = try Harness(env: ["STUB_PI_HISTORY_BYTES": String(2 * 1024 * 1024)])
        defer { h.stop() }
        let order = Locked<[String]>([])
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await h.onQueue {
            h.session.beforeOffQueueDecode = { release.wait() }
            let record = h.session.onEvent
            h.session.onEvent = { event in
                order.withValue { $0.append(Harness.type(event)) }
                record?(event)
            }
            // pi answers the long history, then the prompt, then streams the prompt's turn.
            h.session.request(.getMessages) { result in
                order.withValue { $0.append((try? result.get().messages?.count).map { "history:\($0)" } ?? "history:failed") }
            }
            h.session.request(.prompt(message: "hello")) { _ in order.withValue { $0.append("prompt") } }
        }
        try await eventually("the turn to wait behind the history") { await h.onQueue { h.session.deferredRecordCount } >= 18 }
        #expect(order.current.isEmpty)

        release.signal()
        try await h.waitFor("agent_settled")
        #expect(order.current == ["history:12", "prompt", "agent_start", "turn_start", "message_start"]
            + Array(repeating: "message_update", count: 7)
            + ["message_end", "tool_execution_start", "tool_execution_end", "turn_end", "unknown:stub_unmodelled_event", "agent_end", "agent_settled"])
    }

    /// An answer that arrived before its deadline wins, even while it is still decoding off the
    /// queue when the deadline passes.
    @Test func anAnswerDecodingAtItsDeadlineStillAnswersTheRequest() async throws {
        let h = try Harness(env: ["STUB_PI_HISTORY_BYTES": String(2 * 1024 * 1024)])
        defer { h.stop() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let answer = Locked<Result<RPCResponse, RPCError>?>(nil)
        #expect(try await h.request(.getState).get().success, "pi is up, so its answer arrives well within the deadline")
        await h.onQueue {
            h.session.beforeOffQueueDecode = { release.wait() }
            h.session.request(.getMessages, timeout: 2) { result in answer.withValue { $0 = result } }
        }
        try await eventually("the deadline to pass with the answer decoding") { await h.onQueue { h.session.expiringRequestCount } == 1 }
        #expect(answer.current == nil)

        release.signal()
        try await eventually("the request to be answered") { answer.current != nil }
        #expect((try? answer.current?.get())?.messages?.count == 12)
    }

    /// pi answering a long history and then dying: the answer, still decoding off the queue when
    /// pi is reaped, is handled first; only then does the request pi never answered fail, and
    /// only then is the exit reported.
    @Test func anExitWaitsForTheRecordsStillDecoding() async throws {
        let h = try Harness(env: ["STUB_PI_HISTORY_BYTES": String(2 * 1024 * 1024)])
        defer { h.stop() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let order = Locked<[String]>([])
        #expect(try await h.request(.getState).get().success)
        await h.onQueue {
            h.session.beforeOffQueueDecode = { release.wait() }
            h.session.onExit = { code in order.withValue { $0.append("exit:\(code.map(String.init) ?? "nil")") } }
            h.session.request(.getMessages) { result in
                order.withValue { $0.append((try? result.get().messages?.count).map { "history:\($0)" } ?? "history:failed") }
            }
            h.session.request(.prompt(message: "die")) { result in
                order.withValue { $0.append(result == .failure(.exited(code: 3)) ? "die:exited" : "die:\(result)") }
            }
        }
        try await eventually("pi to die with its history decoding") { await h.onQueue { !h.session.isAlive } }
        #expect(order.current.isEmpty)

        release.signal()
        try await eventually("the exit to be reported") { order.current.count == 3 }
        #expect(order.current == ["history:12", "die:exited", "exit:3"])
    }

    @Test func overlappingRequestsAreCorrelatedByID() async throws {
        let h = try Harness()
        defer { h.stop() }
        async let messages = h.request(.getMessages)
        async let commands = h.request(.getCommands)
        async let stats = h.request(.getSessionStats)
        let (m, c, s) = try await (messages.get(), commands.get(), stats.get())
        #expect(m.command == "get_messages" && m.messages?.count == 2)
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

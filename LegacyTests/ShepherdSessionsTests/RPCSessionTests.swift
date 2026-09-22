import Darwin
import Dispatch
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// Drives `RPCSession` against `Fixtures/stub-pi.py`, a python3 stand-in for
/// `pi --mode rpc` that speaks the documented protocol. Serialized like the
/// other process-spawning suites.
@Suite("RPC session", .serialized)
struct RPCSessionTests {
    static let stubPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stub-pi.py").path

    struct Harness {
        let queue: DispatchQueue
        let session: RPCSession
        let events = Locked<[RPCEvent]>([])
        let stderr = Locked<[String]>([])
        let exited = Locked<(done: Bool, code: Int32?)>((false, nil))

        init(label: String) throws {
            queue = DispatchQueue(label: "test.rpc.\(label)")
            let dir = try makeScratchDirectory()
            session = try RPCSession(
                params: CreateSessionParams(cwd: dir.path, command: ["python3", RPCSessionTests.stubPath]),
                queue: DispatchQueue(label: "test.rpc.\(label).session", target: queue)
            )
            session.onEvent = { [events] event in events.withValue { $0.append(event) } }
            session.onStderr = { [stderr] line in stderr.withValue { $0.append(line) } }
            session.onExit = { [exited] code in exited.withValue { $0 = (true, code) } }
            session.start()
        }

        func request(_ command: RPCCommand, timeout: TimeInterval = 10) async -> Result<RPCResponse, RPCError> {
            await withCheckedContinuation { cont in
                queue.async { session.request(command, timeout: timeout) { cont.resume(returning: $0) } }
            }
        }

        func eventTypes() -> [String] {
            events.current.map { event in
                switch event {
                case .agentStart: return "agent_start"
                case .agentEnd: return "agent_end"
                case .agentSettled: return "agent_settled"
                case .turnStart: return "turn_start"
                case .turnEnd: return "turn_end"
                case .messageStart: return "message_start"
                case .messageUpdate: return "message_update"
                case .messageEnd: return "message_end"
                case .toolExecutionStart: return "tool_execution_start"
                case .toolExecutionUpdate: return "tool_execution_update"
                case .toolExecutionEnd: return "tool_execution_end"
                case .queueUpdate: return "queue_update"
                case .extensionUIRequest: return "extension_ui_request"
                case .extensionError: return "extension_error"
                case .unknown(let type): return "unknown:\(type)"
                }
            }
        }

        func waitForEvent(_ type: String, timeout: Duration = .seconds(30)) async throws -> Bool {
            try await waitUntil(timeout: timeout) { eventTypes().contains(type) }
        }

        func shutdown() async throws {
            queue.sync { session.kill() }
            _ = try await waitUntil(timeout: .seconds(15)) { exited.current.done }
        }
    }

    @Test func spawnAndGetStateRoundTrip() async throws {
        let h = try Harness(label: "state")
        let result = await h.request(.getState)
        let response = try result.get()
        #expect(response.command == "get_state")
        #expect(response.success)
        #expect(response.data?["sessionId"]?.stringValue == "stub-session")
        #expect(response.data?["model"]?["id"]?.stringValue == "claude-sonnet-4-20250514")
        #expect(response.id?.hasPrefix(h.session.id.rawValue) == true)
        h.queue.sync { #expect(h.session.isAlive) }
        try await h.shutdown()
    }

    @Test func streamingTurnFramesOnLFOnlyIncludingU2028() async throws {
        let h = try Harness(label: "stream")
        let accepted = await h.request(.prompt(message: "hello"))
        #expect(try accepted.get().success)
        #expect(try await h.waitForEvent("agent_settled"))

        let types = h.eventTypes()
        #expect(types == [
            "agent_start", "turn_start", "message_start",
            "message_update", "message_update", "message_update", "message_update", "message_update",
            "message_update", "message_update",
            "message_end", "tool_execution_start", "tool_execution_end", "turn_end",
            "unknown:compaction_start", "agent_end", "agent_settled",
        ], "\(types)")

        var deltas: [String] = []
        var toolCallEnd: RPCContentBlock?
        for case .messageUpdate(let delta, let usage) in h.events.current {
            #expect(usage?["totalTokens"]?.doubleValue == 101)
            if delta.type == "text_delta", let text = delta.delta { deltas.append(text) }
            if delta.type == "toolcall_end" { toolCallEnd = delta.toolCall }
        }
        #expect(deltas.joined() == "Hello line\u{2028}sep world")
        #expect(toolCallEnd == .toolCall(id: "call_abc123", name: "bash", arguments: .object(["command": .string("ls")])))

        for case .messageEnd(let message) in h.events.current {
            #expect(message.role == "assistant")
            #expect(message.stopReason == "toolUse")
            #expect(message.content.first == .text("Hello line\u{2028}sep world"))
        }
        for case .toolExecutionEnd(let id, let name, let result, let isError) in h.events.current {
            #expect(id == "call_abc123")
            #expect(name == "bash")
            #expect(result?.content == [.text("total 48\n")])
            #expect(!isError)
        }
        try await h.shutdown()
    }

    @Test func overlappingRequestsCorrelateById() async throws {
        let h = try Harness(label: "correlate")
        async let a = h.request(.getMessages)
        async let b = h.request(.getCommands)
        async let c = h.request(.getSessionStats)
        let (ra, rb, rc) = try await (a.get(), b.get(), c.get())
        #expect(ra.command == "get_messages")
        #expect(ra.data?["messages"]?.arrayValue?.count == 2)
        let messages = try #require(ra.data?["messages"]).decode([RPCMessage].self)
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(messages[0].content == [.text("Hello!")])
        #expect(rb.command == "get_commands")
        #expect(rb.data?["commands"]?.arrayValue?.first?["name"]?.stringValue == "session-name")
        #expect(rc.command == "get_session_stats")
        #expect(rc.data?["contextUsage"]?["percent"]?.doubleValue == 30)
        #expect(Set([ra.id, rb.id, rc.id].compactMap { $0 }).count == 3)
        try await h.shutdown()
    }

    @Test func requestTimesOutWhenPiNeverAnswers() async throws {
        let h = try Harness(label: "timeout")
        let result = await h.request(.prompt(message: "hang"), timeout: 0.5)
        #expect(result == .failure(.timeout))
        // The transport is still usable afterwards.
        #expect(try await h.request(.getState).get().success)
        try await h.shutdown()
    }

    @Test func processDeathFailsOutstandingRequestsAndReportsExitCode() async throws {
        let h = try Harness(label: "die")
        let result = await h.request(.prompt(message: "die"))
        #expect(result == .failure(.exited(code: 3)))
        #expect(try await waitUntil(timeout: .seconds(15)) { h.exited.current.done })
        #expect(h.exited.current.code == 3)
        h.queue.sync {
            #expect(!h.session.isAlive)
            #expect(h.session.exitCode == 3)
        }
        let afterDeath = await h.request(.getState)
        #expect(afterDeath == .failure(.notAlive))
        #expect(try await waitUntil(timeout: .seconds(10)) { h.stderr.current.contains("stub-pi: dying") })
    }

    @Test func killSendsSIGTERMAndReaps() async throws {
        let h = try Harness(label: "kill")
        #expect(try await h.request(.getState).get().success)
        h.queue.sync { h.session.kill() }
        #expect(try await waitUntil(timeout: .seconds(15)) { h.exited.current.done })
        // Python's default SIGTERM disposition terminates by signal (nil code).
        #expect(h.exited.current.code == nil)
        h.queue.sync { #expect(!h.session.isAlive) }
    }

    @Test func dialogRoundTrip() async throws {
        let h = try Harness(label: "dialog")
        #expect(try await h.request(.prompt(message: "ask")).get().success)
        #expect(try await h.waitForEvent("extension_ui_request"))
        var request: RPCExtensionUIRequest?
        for case .extensionUIRequest(let r) in h.events.current { request = r }
        let ui = try #require(request)
        #expect(ui.method == "confirm")
        #expect(ui.id == "uuid-2")
        #expect(ui.title == "Clear session?")
        #expect(ui.message == "All messages will be lost.")
        #expect(ui.timeout == 5000)
        #expect(!h.eventTypes().contains("agent_end"))

        h.queue.sync { h.session.send(.extensionUIResponse(id: ui.id, confirmed: true)) }
        #expect(try await h.waitForEvent("agent_settled"))
        for case .agentEnd(let messages, let willRetry) in h.events.current {
            #expect(!willRetry)
            #expect(messages.first?.content == [.text("confirmed")])
        }
        try await h.shutdown()
    }

    @Test func oversizeRecordIsDroppedWithoutStoppingTheReader() async throws {
        let h = try Harness(label: "big")
        #expect(try await h.request(.prompt(message: "big")).get().success)
        #expect(try await h.waitForEvent("agent_settled"))
        #expect(!h.eventTypes().contains("extension_ui_request"))
        #expect(try await h.request(.getState).get().success)
        try await h.shutdown()
    }

    @Test func stderrIsForwardedLineByLine() async throws {
        let h = try Harness(label: "stderr")
        #expect(try await h.request(.prompt(message: "stderr")).get().success)
        #expect(try await waitUntil(timeout: .seconds(10)) { h.stderr.current.contains("stub-pi: warning line") })
        try await h.shutdown()
    }

    @Test func abortRespondsAndEndsTheRun() async throws {
        let h = try Harness(label: "abort")
        let response = try await h.request(.abort).get()
        #expect(response.command == "abort")
        #expect(try await h.waitForEvent("agent_settled"))
        #expect(h.eventTypes() == ["agent_end", "agent_settled"])
        try await h.shutdown()
    }

    @Test func spawnFailsForMissingExecutable() {
        #expect(throws: RPCSession.SpawnError.self) {
            _ = try RPCSession(
                params: CreateSessionParams(cwd: "/", command: ["/nonexistent/definitely-not-here"]),
                queue: DispatchQueue(label: "test.rpc.missing")
            )
        }
    }
}

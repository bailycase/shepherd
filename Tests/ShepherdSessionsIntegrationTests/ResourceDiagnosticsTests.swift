import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Resource diagnostics", .integrationTimeLimit)
struct ResourceDiagnosticsTests {
    @Test func serverCountersAndLifecycleDurationsFollowTheOwnedSession() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let events = Locked([(String, Double)]())
        host.server.onDiagnosticDuration = { operation, seconds in events.withValue { $0.append((operation, seconds)) } }
        let activities = Locked([String]())
        host.server.onDiagnosticActivity = { activity in
            #expect(Thread.isMainThread)
            activities.withValue { $0.append(activity) }
        }
        let session = try await host.server.createSession(params: .init(cwd: host.dir.path, command: StubPi.command, runtime: .rpc))
        try await eventually("the session to serve") { await host.server.threadServes(sessionID: session.id) }
        let initial = await host.server.resourceState()
        #expect(initial.piPIDs.count == 1)
        #expect(initial.values["sessions.idle"] == 1)
        #expect(initial.values["transcript.rows", default: 0] > 0)
        let prompt = try #require(OpeningPrompt("/session-name fail PRIVATE_SENTINEL", agentID: .init()))
        await host.server.sendOpeningPrompt(prompt, sessionID: session.id)
        try await eventually("a fixed extension failure on main") { activities.withValue { $0 == ["extension.failed"] } }
        host.server.killSession(session.id)
        try await eventually("the stop timing") { events.withValue { $0.contains { $0.0 == "agent.stop" } } }
        let final = await host.server.resourceState()
        #expect(final.piPIDs.isEmpty)
        #expect(events.withValue { $0.contains { $0.0 == "agent.start" } })
        #expect(events.withValue { $0.allSatisfy { $0.1.isFinite && $0.1 >= 0 } })
    }

    @Test func censusReportsNumbersWithoutProcessNamesOrArguments() async {
        let sampler = SessionResourceSampler()
        let values = await sampler.sample(SessionResourceState(piPIDs: [], terminalPIDs: [], values: ["sessions.total": 0]))
        #expect(values["app.rss_bytes", default: 0] > 0)
        #expect(values["app.footprint_bytes", default: 0] > 0)
        #expect(values["system.memory_bytes", default: 0] > 0)
        #expect(values["process_scan.failed"] == 0)
        #expect(values["sessions.total"] == 0)
        #expect(values.values.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    @Test func diagnosticOutcomesExposeOnlyFixedNamesAndExcludeStoppedFailures() async throws {
        let thread = try ThreadEventTests.Thread(bootstrap: false)
        defer { thread.stop() }
        let recorded = Locked([String]())
        thread.queue.sync {
            thread.state.onDiagnosticActivity = { activity in recorded.withValue { $0.append(activity) } }
        }
        let modelFailure = #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"PRIVATE_SENTINEL"}}"#
        let toolFailure = #"{"type":"tool_execution_end","toolCallId":"PRIVATE_SENTINEL","toolName":"PRIVATE_SENTINEL","result":{"content":[{"type":"text","text":"PRIVATE_SENTINEL"}]},"isError":true}"#
        try await thread.feed(
            #"{"type":"agent_start"}"#,
            modelFailure, toolFailure,
            #"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":0,"errorMessage":"PRIVATE_SENTINEL"}"#,
            #"{"type":"compaction_end","reason":"manual","aborted":false,"willRetry":false,"errorMessage":"PRIVATE_SENTINEL"}"#,
            #"{"type":"extension_error","extensionPath":"/PRIVATE_SENTINEL","event":"PRIVATE_SENTINEL","error":"PRIVATE_SENTINEL"}"#)
        let expected = ["model.failed", "tool.failed", "model.retry", "context.compact_failed", "extension.failed"]
        #expect(recorded.withValue { $0 } == expected)
        thread.queue.sync { thread.state.stopRequested = true }
        try await thread.feed(
            modelFailure, toolFailure,
            #"{"type":"compaction_end","reason":"manual","aborted":true,"willRetry":false,"errorMessage":"PRIVATE_SENTINEL"}"#)
        #expect(recorded.withValue { $0 } == expected)
        try await thread.feed(
            #"{"type":"agent_start"}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}"#,
            #"{"type":"tool_execution_end","toolCallId":"PRIVATE_SENTINEL","toolName":"PRIVATE_SENTINEL","result":{"content":[]},"isError":false}"#,
            #"{"type":"compaction_end","reason":"manual","aborted":false,"willRetry":false}"#)
        #expect(recorded.withValue { $0 } == expected)
        thread.queue.sync { thread.state.onDiagnosticActivity = nil }
        try await thread.feed(modelFailure, toolFailure)
        #expect(recorded.withValue { $0 } == expected)
    }

    @Test func aSessionSwitchDiscardsUnfinishedDiagnosticTimings() async throws {
        let thread = try ThreadEventTests.Thread()
        defer { thread.stop() }
        _ = try await thread.ready()
        let recorded = Locked([String]())
        thread.queue.sync {
            thread.state.onDiagnosticDuration = { operation, _ in recorded.withValue { $0.append(operation) } }
        }
        try await thread.feed(
            #"{"type":"compaction_start","reason":"manual"}"#,
            #"{"type":"tool_execution_start","toolCallId":"old","toolName":"bash","args":{}}"#)
        let switched: Result<RPCResponse, RPCError> = await withCheckedContinuation { continuation in
            thread.queue.async { thread.session.request(.newSession) { continuation.resume(returning: $0) } }
        }
        #expect(try switched.get().success)
        let refreshed: Result<RPCResponse, RPCError> = await withCheckedContinuation { continuation in
            thread.queue.async { thread.state.refreshState { continuation.resume(returning: $0) } }
        }
        #expect(try refreshed.get().success)
        try await eventually("the replacement session's history to load") {
            await thread.request(.snapshot()).snapshotValue?.piSessionID == "stub-session-2"
        }
        // A late end must not report the previous session's start, including its idle gap.
        try await thread.feed(
            #"{"type":"compaction_end","reason":"manual","aborted":true,"willRetry":false}"#,
            #"{"type":"tool_execution_end","toolCallId":"old","toolName":"bash","result":{"content":[]},"isError":false}"#)
        #expect(recorded.withValue { !$0.contains("context.compact") && !$0.contains("tool.bash") })
        try await thread.feed(
            #"{"type":"compaction_start","reason":"manual"}"#,
            #"{"type":"compaction_end","reason":"manual","aborted":false,"willRetry":false}"#)
        #expect(recorded.withValue { $0.filter { $0 == "context.compact" }.count } == 1)
    }

    @Test func toolDurationsNeverExposeCustomNamesAndInflightTimingsAreBounded() async throws {
        let thread = try ThreadEventTests.Thread(bootstrap: false)
        defer { thread.stop() }
        let recorded = Locked([(String, Double)]())
        thread.queue.sync {
            thread.state.onDiagnosticDuration = { operation, seconds in recorded.withValue { $0.append((operation, seconds)) } }
        }
        for index in 0..<140 {
            try await thread.feed("{\"type\":\"tool_execution_start\",\"toolCallId\":\"id-\(index)\",\"toolName\":\"PRIVATE_DATABASE_NAME\",\"args\":{}}")
        }
        for index in 0..<140 {
            try await thread.feed("{\"type\":\"tool_execution_end\",\"toolCallId\":\"id-\(index)\",\"toolName\":\"PRIVATE_DATABASE_NAME\",\"result\":{\"content\":[]},\"isError\":false}")
        }
        let calls = recorded.withValue { $0 }
        #expect(calls.count == 128)
        #expect(calls.allSatisfy { $0.0 == "tool.other" && $0.1.isFinite && $0.1 >= 0 })
        try await thread.feed(#"{"type":"tool_execution_start","toolCallId":"mcp","toolName":"mcp__PRIVATE_DATABASE__query","args":{}}"#,
                              #"{"type":"tool_execution_end","toolCallId":"mcp","toolName":"mcp__PRIVATE_DATABASE__query","result":{"content":[]},"isError":false}"#)
        #expect(recorded.withValue { $0.last?.0 } == "tool.mcp")
    }
}

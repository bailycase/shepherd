import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Resource diagnostics", .integrationTimeLimit)
struct ResourceDiagnosticsTests {
    @Test func serverCountersAndLifecycleDurationsFollowTheOwnedSession() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let events = Locked([(String, Double)]())
        host.server.onDiagnosticDuration = { operation, seconds in events.withValue { $0.append((operation, seconds)) } }
        let session = try await host.server.createSession(params: .init(cwd: host.dir.path, command: StubPi.command, runtime: .rpc))
        try await eventually("the session to serve") { await host.server.threadServes(sessionID: session.id) }
        let initial = await host.server.resourceState()
        #expect(initial.piPIDs.count == 1)
        #expect(initial.values["sessions.idle"] == 1)
        #expect(initial.values["transcript.rows", default: 0] > 0)
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

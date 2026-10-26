import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project message refusal details", .integrationTimeLimit)
struct ProjectMessageFailureTests {
    typealias Rig = ProjectRuntimeTests.Rig

    @Test func inputHandledWithoutUserTurnDoesNotFenceLaterMessages() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), uncertain = UUID()
        let sent = try await rig.perform(p.id, .message(operationID: uncertain, text: "/session-name info handled"))
        let id = try #require(sent.coordinatorAgentID)
        let next = UUID()
        _ = try await rig.perform(p.id, .message(operationID: next, text: "after unconfirmed delivery"))
        try await eventually("unconfirmed prompt retired from idle native thread") {
            try await rig.host.server.enqueue {
                rig.host.server.state.projects.first?.messages.first?.phase == .unknown
                    && rig.host.server.rpcThread(forAgent: id)?.piBusy == false
            }
        }
        try await eventually("next explicit message delivered") {
            rig.host.server.state.projects.first?.messages.first(where: { $0.id == next })?.phase == .delivered
        }
        let pi = try #require(rig.agents.current[id])
        #expect(pi.stdin("prompt").filter { $0["message"] as? String == "/session-name info handled" }.count == 1)
        #expect(pi.stdin("prompt").filter { $0["message"] as? String == "after unconfirmed delivery" }.count == 1)
        #expect(rig.host.server.state.projects.first?.messages.first(where: { $0.id == uncertain })?.phase == .unknown)
    }

    @Test(arguments: [false, true])
    func configurationTimeoutDoesNotFenceLaterMessages(thinking: Bool) async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        let sent = try await rig.perform(p.id, .message(operationID: UUID(), text: "first"))
        let id = try #require(sent.coordinatorAgentID)
        try await eventually("initial turn settled") {
            try await rig.host.server.enqueue {
                rig.host.server.state.projects.first?.messages.first?.phase == .delivered
                    && rig.host.server.rpcThread(forAgent: id)?.piBusy == false
            }
        }
        let cwd = rig.host.dir.appendingPathComponent("logical-projects/\(p.id)")
        let marker = cwd.appendingPathComponent(thinking ? "ignore-thinking-response-once" : "ignore-model-response-once")
        try Data().write(to: marker)
        var settings = try #require(rig.host.server.state.projects.first).settings
        if thinking { settings.conversationThinking = "minimal" }
        else { settings.conversationModel = "anthropic/config-timeout" }
        let current = try #require(rig.host.server.state.projects.first)
        _ = try await rig.host.server.logicalProjects(.settings(projectID: p.id, expectedRevision: current.revision, settings: settings))
        let blocked = UUID()
        _ = try await rig.perform(p.id, .message(operationID: blocked, text: "not dispatched"))
        try await eventually("configuration request awaiting its reply") {
            !FileManager.default.fileExists(atPath: marker.path)
        }
        let queued = UUID()
        _ = try await rig.perform(p.id, .message(operationID: queued, text: "after configuration"))
        try await eventually("configuration deadline handled") {
            rig.host.server.state.projects.first?.messages.first(where: { $0.id == blocked })?.phase != .delivering
        }
        let failed = try #require(rig.host.server.state.projects.first?.messages.first(where: { $0.id == blocked }))
        #expect(failed.phase == .failed)
        guard failed.phase == .failed else { return }
        let pi = try #require(rig.agents.current[id])
        #expect(!pi.stdin("prompt").contains { $0["message"] as? String == "not dispatched" })
        try await eventually("queued turn delivered after configuration recovers") {
            rig.host.server.state.projects.first?.messages.first(where: { $0.id == queued })?.phase == .delivered
        }
        #expect(pi.stdin("prompt").filter { $0["message"] as? String == "after configuration" }.count == 1)
    }

    @Test(arguments: [
        ("No API key found for test-provider.", "No API key found for test-provider."),
        ("Invalid api_key=synthetic-secret-value; Bearer synthetic-bearer-token-12345; sk-synthetic0123456789abcdef\u{1B}",
         "Invalid [redacted]; Bearer [redacted]; [redacted]�")
    ])
    func actualPromptRefusalIsPersistedSafelyAndExplicitResendHasNoStaleDetail(_ reason: String, _ safe: String) async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), operation = UUID()
        let refusal = rig.host.dir.appendingPathComponent("logical-projects/\(p.id)/prompt-error")
        try Data(reason.utf8).write(to: refusal)
        let sent = try await rig.perform(p.id, .message(operationID: operation, text: "hello"))
        let coordinator = try #require(sent.coordinatorAgentID)
        try await eventually("real prompt refusal persisted") { rig.host.server.state.projects.first?.messages.first?.phase == .failed }
        #expect(rig.host.server.state.projects.first?.paused == false, "a refused message never pauses the Project")
        let pi = try #require(rig.agents.current[coordinator])
        let expected = "The agent refused it: " + safe
        #expect(rig.host.server.state.projects.first?.messages.first?.failureDetail == expected)
        let stored = try JSONDecoder().decode(ShepherdState.self, from: Data(contentsOf: rig.host.stateURL))
        #expect(stored.projects.first?.messages.first?.failureDetail == expected)
        #expect(pi.stdin("prompt").count == 1)
        let replay = try await rig.perform(p.id, .message(operationID: operation, text: "hello"))
        #expect(replay.messages.first?.failureDetail == expected)
        #expect(pi.stdin("prompt").count == 1, "Retrying admission cannot resend the refused operation")

        try FileManager.default.removeItem(at: refusal)
        let retry = UUID()
        _ = try await rig.perform(p.id, .message(operationID: retry, text: "hello"))
        try await eventually("explicit resend consumed once") {
            rig.host.server.state.projects.first?.messages.last?.phase == .delivered
        }
        let messages = try #require(rig.host.server.state.projects.first?.messages)
        #expect(messages.count == 2 && messages.last?.id == retry)
        #expect(messages.first?.phase == .failed && messages.first?.failureDetail == expected)
        #expect(messages.last?.failureDetail == nil)
        #expect(pi.stdin("prompt").count == 2)
    }
}

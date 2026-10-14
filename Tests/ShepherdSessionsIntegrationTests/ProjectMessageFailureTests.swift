import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project message refusal details", .integrationTimeLimit)
struct ProjectMessageFailureTests {
    typealias Rig = ProjectRuntimeTests.Rig

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

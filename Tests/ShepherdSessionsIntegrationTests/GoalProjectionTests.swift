import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Goal projection", .integrationTimeLimit)
struct GoalProjectionTests {
    static let id = "00000000-0000-0000-0000-000000000001"

    static func widget(_ goal: NativeGoal?) throws -> String {
        let text = "SHEPHERD_GOAL:" + (try goal.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null")
        let event: [String: Any] = ["type": "extension_ui_request", "id": "goal", "method": "setWidget",
                                    "widgetKey": "shepherd.goal", "widgetLines": [text]]
        return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    @Test func goalsAreStructuredChromeNeverOpaqueWidgetText() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        let before = try await t.ready()
        #expect(!before.supportedActions.contains("goal"))
        let goal = NativeGoal(id: Self.id, text: "All tests pass", state: .checking, elapsedSeconds: 12)
        let changed = try await t.feedThenSnapshot(Self.widget(goal))
        #expect(changed.goal == goal)
        #expect(changed.supportedActions.contains("goal"))
        #expect(changed.widgets?.isEmpty == true)
        #expect(changed.revision > before.revision)
        let cleared = try await t.feedThenSnapshot(Self.widget(nil))
        #expect(cleared.goal == nil)
        #expect(cleared.supportedActions.contains("goal"))
    }

    @Test func controlsRejectStaleGoalsAndRemainAvailableWhilePiWorks() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let goal = NativeGoal(id: Self.id, revision: 4, text: "Tests pass", state: .working)
        _ = try await t.feedThenSnapshot(Self.widget(goal))
        try await t.feed(#"{"type":"agent_start"}"#)
        let s = try await t.snapshot()
        let stale = await t.request(.goal(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), action: .pause,
                                          expectedGoalID: Self.id, expectedGoalRevision: 3))
        #expect(stale.failureCode == "stale_goal")
        let invalid = await t.request(.goal(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), action: .edit(text: " ")))
        #expect(invalid.failureCode == "invalid")
        let operation = UUID()
        let request = NativeThreadRequest.goal(expectedSessionID: s.piSessionID, generation: s.generation, operationID: operation,
                                               action: .pause, expectedGoalID: Self.id, expectedGoalRevision: 4)
        let result = await t.request(request)
        #expect(result == .accepted(operationID: operation))
        #expect(await t.request(request) == result, "an operation replay never sends a second command")
    }

    @Test func aRejectedControllerCommandIsNotAcknowledgedAsSuccess() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let s = try await t.feedThenSnapshot(Self.widget(NativeGoal(id: Self.id, revision: 4, text: "Tests pass", state: .working)))
        let result = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.handle(.goal(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                     action: .pause, expectedGoalID: Self.id, expectedGoalRevision: 4)) {
                    continuation.resume(returning: $0)
                }
                t.state.handle(.extensionError(extensionPath: "command:shepherd-goal", event: "command", error: "Goal changed; refresh it."))
            }
        }
        #expect(result.failureCode == "goal_rejected")
    }

    @Test func aSecondGoalControlWaitsForTheFirstCommandToFinish() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let s = try await t.feedThenSnapshot(Self.widget(NativeGoal(id: Self.id, revision: 4, text: "Tests pass", state: .working)))
        let result = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.handle(.goal(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), action: .pause)) { _ in }
                t.state.handle(.goal(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), action: .clear)) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(result.failureCode == "busy")
    }

    @Test func aPiWithoutTheControllerRefusesGoalControls() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        let s = try await t.ready()
        let result = await t.request(.goal(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), action: .pause))
        #expect(result.failureCode == "unsupported")
    }
}

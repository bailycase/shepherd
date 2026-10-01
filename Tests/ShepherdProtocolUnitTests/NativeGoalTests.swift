import Foundation
import Testing
import ShepherdProtocol

@Suite("Goal wire and validation")
struct NativeGoalTests {
    static let id = "00000000-0000-0000-0000-000000000001"

    @Test(arguments: NativeGoalState.allCases)
    func everyGoalStateRoundTripsAndFormatsUsage(_ state: NativeGoalState) throws {
        let goal = NativeGoal(id: Self.id, text: "Tests pass without modifying the consumer", state: state,
                              elapsedSeconds: 400, tokensUsed: 71000, reason: "Checking test output", evidence: "41 tests passed")
        #expect(goal.isValid)
        #expect(try Wire.roundTrip(goal) == goal)
        #expect(goal.timeLabel == "6m 40s")
        if state == .working { #expect(goal.metaLabel == "71k tokens") }
        if state == .met { #expect(goal.metaLabel == "71k tokens · 41 tests passed") }
        let widget = "SHEPHERD_GOAL:" + String(decoding: try JSONEncoder().encode(goal), as: UTF8.self)
        #expect(NativeGoal.readWidget(widget) == goal)
    }

    @Test func malformedOrUnboundedWidgetsCannotBecomeGoalState() throws {
        #expect(NativeGoal.readWidget("SHEPHERD_GOAL:null") == nil)
        #expect(NativeGoal.readWidget("SHEPHERD_GOAL:{\"state\":\"met\"}") == nil)
        #expect(NativeGoal.readWidget("SHEPHERD_GOAL:" + String(repeating: "x", count: 32769)) == nil)
        var goal = NativeGoal(id: Self.id, text: "Tests pass", state: .working)
        goal.tokensUsed = -1
        #expect(!goal.isValid)
        goal.tokensUsed = 0
        goal.elapsedSeconds = .infinity
        #expect(!goal.isValid)
        #expect(!NativeGoalAction.set(text: " ").isValid)
        #expect(!NativeGoalAction.set(text: "Tests pass", timeLimitSeconds: -1).isValid)
        #expect(!NativeGoalAction.set(text: "Tests pass", tokenLimit: 0).isValid)
    }

    @Test(arguments: [NativeGoalAction.set(text: "tests pass", timeLimitSeconds: 1800, tokenLimit: 100000), .pause, .resume, .clear, .edit(text: "tests and lint pass")])
    func everyControlRoundTripsWithoutTurningItsTextIntoInstructions(_ action: NativeGoalAction) throws {
        let request = NativeThreadRequest.goal(expectedSessionID: "s", generation: "g", operationID: UUID(), action: action,
                                               expectedGoalID: Self.id, expectedGoalRevision: 3)
        #expect(try Wire.roundTrip(request) == request)
        #expect(action.command.hasPrefix("/shepherd-goal {"))
        let body = Data(action.command.dropFirst("/shepherd-goal ".count).utf8)
        #expect(try JSONSerialization.jsonObject(with: body) is [String: Any])
    }

    @Test func oldSnapshotsHaveNoGoalAndNewSnapshotsKeepIt() throws {
        var snapshot = try NativeThreadWireTests.snapshot(adding: [:])
        #expect(snapshot.goal == nil)
        snapshot.goal = NativeGoal(id: Self.id, text: "tests pass", state: .paused)
        #expect(try Wire.roundTrip(snapshot).goal == snapshot.goal)
        let met = NativeGoal(id: Self.id, text: "tests pass", state: .met)
        #expect(met.metaLabel == "0 tokens")
    }
}

import Foundation
import Testing
import ShepherdProtocol

@Suite("Goal wire and validation")
struct NativeGoalTests {
    static let id = "00000000-0000-0000-0000-000000000001"

    @Test(arguments: NativeGoalState.allCases)
    func everyGoalStateRoundTripsAndFormatsUsage(_ state: NativeGoalState) throws {
        let goal = NativeGoal(id: Self.id, text: "Tests pass without modifying the consumer", state: state,
                              elapsedSeconds: 400, tokensUsed: 71000, reason: "checking go test, go vet",
                              evidence: "entry-proof: 41 tests passed\twith full output\non the next line", summary: "41 tests passed")
        #expect(goal.isValid)
        #expect(try Wire.roundTrip(goal) == goal)
        #expect(goal.timeLabel == "6m 40s")
        if state == .working { #expect(goal.metaLabel == "71k tokens") }
        if state == .met { #expect(goal.metaLabel == "71k tokens · 41 tests passed") }
        if state == .paused { #expect(goal.metaLabel == "paused by you · the clock stops") }
        if state == .checking || state == .needsYou { #expect(goal.metaLabel == "checking go test, go vet") }
        #expect(!goal.metaLabel.contains("entry-proof"))
        #expect(!goal.metaLabel.contains("\t"))
        #expect(!goal.metaLabel.contains("\n"))
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

    @Test func summaryIsAdditiveAndLegacyMetEvidenceNeverBecomesMetadata() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","revision":1,"text":"Tests pass","state":"met","elapsedSeconds":0,"tokensUsed":71000,"evidence":"entry-proof: 41 tests passed\tmore proof\non another line"}"#
        let legacy = try JSONDecoder().decode(NativeGoal.self, from: Data(json.utf8))
        #expect(legacy.summary == nil)
        #expect(legacy.metaLabel == "71k tokens")
        #expect(try Wire.roundTrip(legacy) == legacy)
        var modern = legacy
        modern.summary = "41 tests passed"
        #expect(try Wire.roundTrip(modern).metaLabel == "71k tokens · 41 tests passed")
        modern.summary = String(repeating: "x", count: 41)
        #expect(!modern.isValid)
    }

    @Test func legacyHeadersAreOneLineIDFreeAndWordBoundedAndPausedAlwaysUsesItsClockMessage() {
        var goal = NativeGoal(id: Self.id, text: "Tests pass", state: .needsYou,
                              reason: "WAITING\tfor permission entryId proof\nDetailed feedback\twith raw proof")
        #expect(goal.metaLabel == "waiting for permission")
        goal.reason = "Waiting for permission \(Self.id) abcdef12 toolCallId call-1"
        #expect(goal.metaLabel == "waiting for permission")
        goal.reason = String(repeating: "remaining permission checks ", count: 20).trimmingCharacters(in: .whitespaces)
        #expect(goal.metaLabel.count <= 40)
        #expect(goal.reason!.hasPrefix(goal.metaLabel))
        #expect(goal.reason!.dropFirst(goal.metaLabel.count).first == " ")
        goal.state = .paused
        #expect(goal.metaLabel == "paused by you · the clock stops")
        goal.text = "Edited while paused"
        #expect(goal.metaLabel == "paused by you · the clock stops")
        goal.state = .checking; goal.reason = nil
        #expect(goal.metaLabel == "checking · commands unavailable")
        goal.reason = "checking read LedgerTests.swift"
        #expect(goal.metaLabel == "checking read LedgerTests.swift")
        goal.state = .met; goal.summary = "41\ttests passed entryId proof\nMore proof"
        #expect(goal.metaLabel == "0 tokens · 41 tests passed")
    }

    @Test func runtimeGeneratedSnapshotsSupplyAllFiveHumanMetadataLinesAndDisclosedProof() throws {
        struct Fixture: Decodable {
            struct Record: Decodable { let content: String }
            let goals: [NativeGoal]
            let records: [Record]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("Tests/Extensions/goal-runtime-fixtures.json")))
        #expect(fixture.goals.count == NativeGoalState.allCases.count)
        #expect(Set(fixture.goals.map(\.state)) == Set(NativeGoalState.allCases))
        let expected: [String: String] = [
            "working": "71k tokens", "checking": "checking go test, go vet", "met": "104k tokens · 41 tests passed",
            "paused": "paused by you · the clock stops", "needsYou": "the same test failed 3 times in a row",
        ]
        for goal in fixture.goals {
            #expect(goal.isValid)
            #expect(goal.timeLabel == "6m 40s")
            #expect(goal.metaLabel == expected[goal.state.rawValue])
            #expect(try Wire.roundTrip(goal) == goal)
            for text in [goal.reason, goal.summary, goal.metaLabel].compactMap({ $0 }) {
                #expect(text.utf16.count <= 40)
                #expect(!text.contains("\t") && !text.contains("\n") && !text.contains("\r"))
                #expect(!text.contains(goal.id) && !text.contains("proof") && !text.contains("call-check-1"))
            }
        }
        let met = try #require(fixture.records.first?.content)
        let parts = met.components(separatedBy: "\n\nDetails:\n")
        #expect(parts.first == "Goal met · 41 tests passed")
        #expect(parts.count == 2)
        #expect(parts[1].contains("proof: 41 tests passed\tgo vet is clean\nFull ledger proof."))
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

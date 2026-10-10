import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions

@Suite("Worker plan persisted result projection")
struct NativeProjectPlanProjectionTests {
    @Test func canonicalExtensionResultsSurviveNativeHistoryReplayWithoutAuthority() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Extensions/project-plan-results.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var messages: [RPCMessage] = []
        for row in fixture {
            let id = try #require(row["id"] as? String)
            var result = try #require(row["result"] as? [String: Any])
            result["role"] = "toolResult"; result["toolName"] = "project_plan"; result["toolCallId"] = id
            let raw = try JSONDecoder().decode(RPCMessage.self, from: JSONSerialization.data(withJSONObject: result))
            messages.append(raw)
            #expect(raw.projectAction == nil)
            let projected = RPCThreadState.project(entryID: id, message: raw)
            #expect(projected.projectAction == nil)
            #expect(projected.blocks.map(\.text) == raw.content.compactMap { if case .text(let text) = $0 { text } else { nil } })
        }
        // Encode/decode the persisted tool messages, then use the same projection as get_messages.
        let restored = try JSONDecoder().decode([RPCMessage].self, from: JSONEncoder().encode(messages))
        let history = RPCThreadState.projectHistory(restored)
        let live = RPCThreadState.projectHistory(messages)
        #expect(history == live)
        #expect(NativeProjectPlan(history[0])?.steps.map(\.state) == [.current, .pending])
        #expect(NativeProjectPlan(history[1])?.steps.map(\.state) == [.done, .failed])
        #expect(NativeProjectPlan(history[2])?.steps.first?.text == "Check [redacted]")
        #expect(NativeProjectPlan(history[3]) == nil)
        let presentation = nativeTurnPresentation(history, live: false)
        #expect(presentation.latestProjectPlan == NativeProjectPlan(history[2]))
        #expect(presentation.toolCalls == 4)
        let roundTrip = try JSONDecoder().decode([NativeThreadMessage].self, from: JSONEncoder().encode(history))
        #expect(nativeTurnPresentation(roundTrip, live: false) == presentation)
    }

    @Test func maximumEscapedPlanAndArgumentsFitWithoutChangingOrdinaryRowBudget() throws {
        let steps = Array(repeating: ["text": String(repeating: "\u{0001}", count: 499) + "x", "state": "pending"], count: 20)
        let arguments = try JSONSerialization.data(withJSONObject: ["steps": steps])
        let output = String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1, "steps": steps]), as: UTF8.self)
        let args = try JSONDecoder().decode(JSONValue.self, from: arguments)
        var raw = RPCMessage(role: "toolResult", content: [.text(output)], toolName: "project_plan", toolCallId: "max")
        let plan = RPCThreadState.project(entryID: "max", message: raw, args: args)
        #expect(!plan.truncated)
        #expect(NativeProjectPlan(plan)?.steps.count == 20)
        raw.toolName = "bash"
        #expect(RPCThreadState.project(entryID: "ordinary", message: raw, args: args).truncated)
    }
}

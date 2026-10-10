import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Explicit worker plan presentation")
struct NativeProjectPlanTests {
    private func message(_ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "plan", role: "toolResult", blocks: [.init(kind: .text, text: text)],
                            toolName: "project_plan", toolCallID: "plan", status: "complete")
    }

    private func report(text: String = "Build", state: String = "current", count: Int = 1) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1,
            "steps": Array(repeating: ["text": text, "state": state], count: count)]), as: UTF8.self)
    }

    @Test func invalidOrUnrecognizedResultsKeepGenericOutput() throws {
        let valid = try report()
        var variants = try ["", "not JSON", "Plan: " + valid, "```json\n" + valid + "\n```", "{}",
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            report(text: " "), report(text: String(repeating: "x", count: 501)),
            report(text: String(repeating: "😀", count: 251)), report(state: "success"), report(count: 0), report(count: 21),
            String(repeating: " ", count: 65_537) + valid].map(message)
        for status in ["running", "streaming", "error", "aborted"] {
            var value = message(valid); value.status = status; variants.append(value)
        }
        var failed = message(valid); failed.isError = true; variants.append(failed)
        var truncated = message(valid); truncated.truncated = true; variants.append(truncated)
        for tool in ["bash", "project_publish", "foreign_project_plan"] {
            var value = message(valid); value.toolName = tool; variants.append(value)
        }
        for role in ["assistant", "user", "custom"] {
            var value = message(valid); value.role = role; variants.append(value)
        }
        var extraBlock = message(valid); extraBlock.blocks.append(.init(kind: .text, text: "done")); variants.append(extraBlock)
        var argumentsOnly = message(""); argumentsOnly.argumentsText = valid; variants.append(argumentsOnly)
        for value in variants {
            #expect(NativeProjectPlan(value) == nil)
            let call = NativeActivityCall(value)
            #expect(call.projectPlan == nil)
            #expect(call.output == value.blocks.map(\.text).joined(separator: "\n"))
        }
        #expect(NativeProjectPlan(message(try report(text: String(repeating: "😀", count: 250), count: 20)))?.steps.count == 20)
    }

    @Test func explicitUpdatesStayOrderedSeparateAndScopedToTheirNativeTurn() throws {
        let first = message(try report())
        var update = message(try report(text: "Publish", state: "failed")); update.toolCallID = "update"
        let prose = NativeThreadMessage(entryID: "words", role: "assistant", blocks: [.init(kind: .text, text: "Everything is done and published.")])
        var failed = update; failed.toolCallID = "error"; failed.isError = true
        let rows = [first, update, failed, prose]
        let presentation = nativeTurnPresentation(rows, live: false)
        #expect(presentation.latestProjectPlan?.steps.map(\.state) == [.failed])
        guard case .activity(_, let bursts) = presentation.items.first else { Issue.record("Missing activity"); return }
        #expect(bursts.map(\.calls.count) == [1, 1, 1])
        #expect(bursts[0].calls[0].projectPlan?.steps.map(\.state) == [.current])
        #expect(presentation.toolCalls == 3)
        let restored = try JSONDecoder().decode([NativeThreadMessage].self, from: JSONEncoder().encode(rows))
        #expect(nativeTurnPresentation(restored, live: false) == presentation)
        #expect(nativeTurnPresentation(restored, live: true).latestProjectPlan == presentation.latestProjectPlan)
        let next = NativeThreadMessage(entryID: "manual", role: "user", blocks: [.init(kind: .text, text: "New manual turn")])
        let turns = nativeTurns(rows + [next, prose])
        #expect(nativeTurnPresentation(try #require(turns.last).messages, live: true).latestProjectPlan == nil)
        #expect(nativeTurnPresentation([first], live: false).latestProjectPlan?.steps.first?.state == .current)
    }

    @Test func displayRedactsWithoutChangingRawHistoryOrGrantingAuthority() throws {
        let source = try report(text: "Check api_key=fixture-secret-value")
        let call = NativeActivityCall(message(source))
        #expect(call.projectPlan?.steps.first?.text == "Check [redacted]")
        #expect(call.output == source)
        #expect(call.projectAction == nil)
    }
}

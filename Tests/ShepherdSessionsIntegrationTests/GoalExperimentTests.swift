import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Goal experiment policy", .integrationTimeLimit)
struct GoalExperimentTests {
    @Test func theDefaultOffExperimentRejectsControlsAndLiveTogglesPreserveAPausedGoal() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let file = host.dir.appendingPathComponent("goal.json")
        let goal = NativeGoal(id: GoalProjectionTests.id, text: "Tests pass", state: .working, tokensUsed: 999999)
        try JSONEncoder().encode(goal).write(to: file)
        let pi = try await PiAgent.launch(on: host, env: ["STUB_PI_GOAL_FILE": file.path,
                                                        "SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "0"])
        let before = try await pi.snapshot("the disabled goal controller to load") { $0.commands != nil }
        #expect(before.goal == nil && !before.supportedActions.contains("goal"))
        #expect(before.commands?.contains { $0.name == "goal" } == false)
        #expect((try await pi.send("/goal Tests pass", from: before)).failureCode == "unsupported")
        #expect((try await pi.send("/shepherd-goal\t{\"action\":\"configure\",\"enabled\":true}", from: before)).failureCode == "invalid")
        #expect((try await pi.request(.goal(expectedSessionID: before.piSessionID, generation: before.generation,
                                           operationID: UUID(), action: .set(text: "Tests pass")))).failureCode == "unsupported")

        host.server.setGoalsEnabled(true)
        let on = try await pi.snapshot("the live goal toggle to publish its preserved goal") { $0.goal?.id == goal.id }
        #expect(on.supportedActions.contains("goal") && on.commands?.contains { $0.name == "goal" } == true)
        host.server.setGoalsEnabled(false)
        let off = try await pi.snapshot("off to remove goal chrome") { $0.goal == nil && !$0.supportedActions.contains("goal") }
        // A late in-flight publication cannot bring the card or native controls back.
        _ = try await pi.send("feed " + GoalProjectionTests.widget(goal), from: off)
        let disabled = try await pi.snapshot("the late widget to be ignored") { $0.goal == nil }
        #expect((try await pi.request(.goal(expectedSessionID: disabled.piSessionID, generation: disabled.generation,
                                           operationID: UUID(), action: .resume, expectedGoalID: goal.id,
                                           expectedGoalRevision: goal.revision, expectedGoalState: .working))).failureCode == "unsupported")
        host.server.setGoalsEnabled(true)
        let restored = try await pi.snapshot("re-enable to keep the original goal paused") { $0.goal?.state == .paused }
        #expect(restored.goal?.id == goal.id && restored.goal?.text == goal.text && restored.goal?.tokensUsed == 999999)
        #expect(restored.generation == before.generation, "the toggle never restarts the process")
        #expect((await host.server.listSessions()).first { $0.id == pi.sessionID }?.isAlive == true)
        let operation = UUID()
        #expect(try await pi.send("tools:0 ordinary follow-up", operationID: operation, from: restored) == .accepted(operationID: operation))
        let finished = try await pi.snapshot("ordinary work to finish") { !$0.running && $0.messages.contains { $0.operationID == operation } }
        #expect(finished.goal?.tokensUsed == 999999 && finished.goal?.state == .paused)
        #expect(pi.stdin("abort").isEmpty)
        let configurations = pi.stdin("prompt").compactMap { $0["message"] as? String }.filter { $0.contains("\"action\":\"configure\"") }
        #expect(configurations.contains { $0.contains("\"enabled\":false") })
        #expect(configurations.contains { $0.contains("\"enabled\":true") })
    }

    @Test func disablingDuringAToolPreservesTheToolAndOrdinaryQueueAndQueueEditsCannotEnableHiddenGoalWork() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let file = host.dir.appendingPathComponent("goal.json")
        let goal = NativeGoal(id: GoalProjectionTests.id, text: "Tests pass", state: .working, tokensUsed: 999999)
        try JSONEncoder().encode(goal).write(to: file)
        host.server.setGoalsEnabled(true)
        let pi = try await PiAgent.launch(on: host, env: ["STUB_PI_GOAL_FILE": file.path,
                                                        "SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "1"])
        let ready = try await pi.snapshot("goal controls to load") { $0.goal?.id == goal.id }
        _ = try await pi.send("tools:1 held", from: ready)
        let running = try await pi.snapshot("the real tool to wait") { $0.running && $0.provisional.contains { $0.toolCallID != nil && $0.status == "running" } }
        let queuedID = UUID()
        _ = try await pi.send("tools:0 ordinary queued turn", operationID: queuedID, from: running)
        let queued = try await pi.snapshot("the ordinary queued row") { $0.queue?.items.first?.id == queuedID }
        let hidden = "/shepherd-goal {\"action\":\"configure\",\"enabled\":true}"
        #expect((try await pi.queue(.edit(id: queuedID, text: hidden), from: queued)).failureCode == "invalid")
        host.server.setGoalsEnabled(false)
        let off = try await pi.snapshot("the tool and ordinary row to survive disable") { $0.goal == nil && $0.running && $0.queue?.items.first?.id == queuedID }
        #expect((try await pi.queue(.edit(id: queuedID, text: "/goal invisible work"), from: off)).failureCode == "unsupported")
        #expect((try await pi.queue(.edit(id: queuedID, text: hidden), from: off)).failureCode == "invalid")
        host.server.setGoalsEnabled(true)
        let restored = try await pi.snapshot("paused goal with the original running tool and queued row") { $0.goal?.state == .paused && $0.running && $0.queue?.items.first?.text == "tools:0 ordinary queued turn" }
        #expect(restored.generation == ready.generation && restored.goal?.tokensUsed == 999999)
        #expect(restored.provisional.contains { $0.toolCallID != nil && $0.status == "running" })
        pi.finishTool(1)
        let finished = try await pi.snapshot("the tool followed by ordinary queued work to finish") { !$0.running && $0.queue?.items.isEmpty == true && $0.messages.contains { $0.operationID == queuedID } && $0.messages.last?.role == "assistant" }
        #expect(finished.goal?.state == .paused && finished.goal?.tokensUsed == 999999)
        #expect(pi.stdin("abort").isEmpty && pi.stdin("clear_queue").isEmpty)
        let configurations = pi.stdin("prompt").filter { ($0["message"] as? String)?.contains("\"action\":\"configure\"") == true }
        #expect(configurations.allSatisfy { $0["id"] == nil }, "edited user input never became an internal configuration request")
    }

    @Test(arguments: ["/goal tools:0 these are quoted words", "/shepherd-goal tools:0 these are quoted words"])
    func aSlashPrefixInsideBrowserContextRemainsOrdinaryContentWhenGoalsAreOff(_ text: String) async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host, env: ["SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "0"])
        let ready = try await pi.ready(), operation = UUID()
        let element = BrowserElement(page: "http://localhost:5173/checkout", selector: "button.pay", label: "Pay", width: 240, height: 44, html: "<button>Pay</button>")
        #expect(try await pi.request(.send(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: operation,
                                          text: text, delivery: .followUp, browserElements: [element])) == .accepted(operationID: operation))
        _ = try await pi.snapshot("the fenced ordinary turn to finish") { !$0.running && $0.messages.contains { $0.operationID == operation } && $0.messages.last?.role == "assistant" }
        let prompt = try #require(pi.stdin("prompt").compactMap { $0["message"] as? String }.last)
        let parsed = try #require(BrowserElementFence.parse(prompt))
        #expect(parsed.text == text && parsed.elements == [element.clamped])
    }
}

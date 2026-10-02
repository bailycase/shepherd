import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Real server mutations and host/controller boundaries. The stub only publishes the controller's
/// widget and acknowledges its immediate commands; automatic goal turns belong to pinned-pi tests.
@Suite("Goal server and queue", .integrationTimeLimit)
struct GoalServerTests {
    private struct Notice: Equatable, Sendable {
        let title: String
        let body: String
    }

    private func launch(_ host: ScratchServer) async throws -> PiAgent {
        let file = host.dir.appendingPathComponent("goal.json")
        try Data("null".utf8).write(to: file)
        host.server.setGoalsEnabled(true)
        let pi = try await PiAgent.launch(on: host, env: ["STUB_PI_GOAL_FILE": file.path, "SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "1"])
        _ = try await pi.snapshot("the goal controller to serve") { $0.supportedActions.contains("goal") }
        return pi
    }

    @discardableResult
    private func publish(_ goal: NativeGoal?, to pi: PiAgent) async throws -> NativeThreadSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(goal).write(to: pi.host.dir.appendingPathComponent("goal.json"), options: .atomic)
        return try await pi.snapshot("the controller's goal widget") { $0.goal == goal }
    }

    private func goal(_ state: NativeGoalState, reason: String? = nil, evidence: String? = nil, summary: String? = nil) -> NativeGoal {
        NativeGoal(id: GoalProjectionTests.id, text: "PRIVATE_GOAL_TEXT", state: state, tokensUsed: 1234,
                   reason: reason, evidence: evidence, summary: summary)
    }

    private func start(_ pi: PiAgent) async throws -> NativeThreadSnapshot {
        _ = try await publish(goal(.working), to: pi)
        _ = try await pi.send("tools:1 build", from: try await pi.ready())
        return try await pi.snapshot("the running tool") { s in
            s.running && s.provisional.contains { $0.toolCallID == "call_q1" && $0.status == "running" }
        }
    }

    private func actions(_ pi: PiAgent) -> [String] {
        pi.stdin("prompt").compactMap { row in
            guard let text = row["message"] as? String, text.hasPrefix("/shepherd-goal "),
                  let value = try? JSONSerialization.jsonObject(with: Data(text.dropFirst("/shepherd-goal ".count).utf8)) as? [String: Any]
            else { return nil }
            let action = value["action"] as? String
            // Host experiment setup is not a queue/Stop/Steer lifecycle action.
            return action == "status" || action == "configure" ? nil : action
        }
    }

    private func prompts(_ pi: PiAgent) -> [String] {
        pi.stdin("prompt").compactMap { $0["message"] as? String }.filter { !$0.hasPrefix("/shepherd-goal ") }
    }

    @Test func goalWidgetsUpdateLiveFleetStateAndNotifyOnlyWithSafeHumanMeta() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let notices = Locked<[Notice]>([])
        host.server.onNotify = { _, title, body in notices.withValue { $0.append(Notice(title: title, body: body)) } }
        let pi = try await launch(host)
        _ = try await publish(goal(.working), to: pi)
        let disk = try Data(contentsOf: host.stateURL)

        let needs = goal(.needsYou, reason: "permission needed \"PRIVATE_TOOL_QUOTE\" `PRIVATE_COMMAND`", evidence: "PRIVATE_EVIDENCE")
        _ = try await publish(needs, to: pi)
        try await eventually("the blocked goal and notification") {
            let agent = host.server.state.agents.first
            return agent?.goalState == "needsYou" && agent?.status == .blocked && agent?.waitingOn == needs.metaLabel
                && notices.current.count == 1
        }
        #expect(notices.current == [Notice(title: "Goal needs you", body: needs.notificationLabel)])
        #expect(host.server.state.agents.first?.waitingReason == nil)
        #expect(try Data(contentsOf: host.stateURL) == disk, "goal state and status are live, not persisted")

        // Accounting and diagnostic updates do not announce a second transition.
        var refreshed = needs
        refreshed.tokensUsed += 1
        refreshed.evidence = "DIFFERENT_PRIVATE_EVIDENCE"
        _ = try await publish(refreshed, to: pi)
        await drainMainQueue()
        #expect(notices.current.count == 1)

        for state in [NativeGoalState.paused, .working, .checking, .met] {
            let next = goal(state, reason: "PRIVATE_REASON", evidence: "PRIVATE_EVIDENCE", summary: "PRIVATE_CHECKER_SUMMARY")
            _ = try await publish(next, to: pi)
            try await eventually("the \(state) fleet state") {
                let agent = host.server.state.agents.first
                return agent?.goalState == state.rawValue && agent?.status == .done && agent?.waitingOn == nil
            }
        }
        try await eventually("the goal met notification") { notices.current.count == 2 }
        #expect(notices.current.last == Notice(title: "Goal met", body: goal(.met, summary: "PRIVATE_CHECKER_SUMMARY").notificationLabel))
        #expect(notices.current.allSatisfy { !$0.body.contains("PRIVATE") && $0.body.utf16.count <= 80 })
        _ = try await publish(nil, to: pi)
        #expect(host.server.state.agents.first?.goalState == nil)
        #expect(host.server.state.agents.first?.waitingOn == nil)
    }

    @Test(arguments: [false, true])
    func idleReportsPreserveABlockedGoalAndAChangedGoalClearsIt(clear: Bool) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let callbacks = Callbacks(host.server)
        let pi = try await launch(host)
        let client = try ExtensionClient(path: host.socketPath)
        defer { client.closeConnection() }
        _ = try await publish(goal(.needsYou, reason: "permission needed"), to: pi)
        for (reported, expected) in [(AgentStatus.done, AgentStatus.blocked), (.idle, .blocked), (.working, .working), (.done, .blocked)] {
            let seen = callbacks.statuses.current.count
            try client.send(.setAgentStatus(agentID: pi.agent.id, status: reported))
            try await eventually("the \(reported) report") { callbacks.statuses.current.count > seen }
            #expect(callbacks.statuses.current.last?.1 == expected)
            #expect(host.server.state.agents.first?.status == expected)
            #expect(host.server.state.agents.first?.waitingOn == "permission needed")
        }
        _ = try await publish(clear ? nil : goal(.paused), to: pi)
        #expect(host.server.state.agents.first?.goalState == (clear ? nil : "paused"))
        #expect(host.server.state.agents.first?.status == .done)
        #expect(host.server.state.agents.first?.waitingOn == nil)
        try client.send(.setAgentStatus(agentID: pi.agent.id, status: .idle))
        try await eventually("an idle report without a blocked goal") { host.server.state.agents.first?.status == .idle }
    }

    @Test func aGoalChangeKeepsAnOpenQuestionsTitleAndShortReason() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        _ = try await publish(goal(.working), to: pi)
        _ = try await pi.send("ask-short", from: try await pi.ready())
        let question = try await pi.snapshot("the open question") { !$0.dialogs.isEmpty }
        try await eventually("the question's short reason") { host.server.state.agents.first?.waitingReason == "retention?" }
        for state in [NativeGoalState.needsYou, .paused] {
            _ = try await publish(goal(state, reason: "decision needed"), to: pi)
            #expect(host.server.state.agents.first?.waitingOn == question.dialogs.first?.title)
            #expect(host.server.state.agents.first?.waitingReason == "retention?")
            #expect(host.server.state.agents.first?.status == .blocked)
        }
        _ = try await pi.request(.answer(expectedSessionID: question.piSessionID, generation: question.generation,
                                         operationID: UUID(), dialogID: question.dialogs[0].id, answer: .select(value: "30 days")))
        _ = try await pi.snapshot("the answered question") { !$0.running && $0.dialogs.isEmpty }
        #expect(host.server.state.agents.first?.waitingOn == nil)
    }

    @Test func queuedInputYieldsAndUnyieldsOnlyAfterThePendingPromptLands() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        let id = UUID()
        _ = try await pi.send("tools:0 hold-start next", operationID: id, from: running)
        try await eventually("yield to host input") { actions(pi) == ["yield"] }
        #expect(prompts(pi) == ["tools:1 build"], "the host still owns the input")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            host.server.changes.captureQueue(pi.agent.id).async { continuation.resume(); release.wait() }
        }
        pi.finishTool(1)
        let captured = try await pi.snapshot("the queued input waiting for capture") { !$0.running }
        #expect(captured.queue?.items.map(\.id) == [id])
        #expect(actions(pi) == ["yield"], "no wake while host input is still waiting")
        release.signal()
        _ = try await pi.snapshot("the dispatched prompt still pending") { s in
            s.queue?.items.isEmpty == true && s.provisional.contains { $0.entryID == "pending:\(id.uuidString)" }
        }
        #expect(actions(pi) == ["yield"], "a pending dispatch still owns the yield")
        FileManager.default.createFile(atPath: host.dir.appendingPathComponent("start").path, contents: nil)
        let done = try await pi.snapshot("the queued input answered") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == id }
        }
        try await eventually("unyield after delivery") { actions(pi) == ["yield", "unyield"] }
        #expect(prompts(pi) == ["tools:1 build", "tools:0 hold-start next"])
        #expect(done.messages.first { $0.operationID == id }?.origin?.parts?.map(\.id) == [id])
        #expect(done.provisional.isEmpty)
    }

    @Test func eachQueuedTurnYieldsAgainWhileAnotherOneAtATimeRowIsWaiting() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        _ = try await pi.queue(.setMode(mode: .oneAtATime), from: running)
        let first = UUID(), second = UUID()
        _ = try await pi.send("tools:1 first", operationID: first, from: running)
        _ = try await pi.send("tools:0 second", operationID: second, from: running)
        try await eventually("both queued messages to yield") { actions(pi) == ["yield", "yield"] }
        #expect(try await pi.snapshot().queue?.items.map(\.id) == [first, second])

        pi.finishTool(1)
        _ = try await pi.snapshot("A running with B still on the host") { s in
            s.running && s.queue?.items.map(\.id) == [second]
                && s.provisional.contains { $0.toolCallID == "call_q2" && $0.status == "running" }
        }
        // before_agent_start clears the runtime's yield. A must receive a fresh one while
        // B still waits, before A's tool finishes and its goal check can continue the worker.
        try await eventually("A to yield again before its goal check") { actions(pi) == ["yield", "yield", "yield"] }
        #expect(prompts(pi) == ["tools:1 build", "tools:1 first"])

        pi.finishTool(2)
        let done = try await pi.snapshot("both queued turns answered in order") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == second }
                && s.messages.last?.role == "assistant"
        }
        try await eventually("the last queued turn to unyield") { actions(pi) == ["yield", "yield", "yield", "unyield"] }
        #expect(prompts(pi) == ["tools:1 build", "tools:1 first", "tools:0 second"])
        #expect(done.messages.filter { $0.operationID == first || $0.operationID == second }.map(\.operationID) == [first, second])
        #expect(done.messages.first { $0.operationID == first }?.origin?.parts?.map(\.id) == [first])
        #expect(done.messages.first { $0.operationID == second }?.origin?.parts?.map(\.id) == [second])
    }

    @Test(arguments: [false, true])
    func removingTheLastQueuedRowUnyieldsWithoutSendingDeletedInput(clear: Bool) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        let first = UUID(), last = UUID()
        _ = try await pi.send("tools:0 first", operationID: first, from: running)
        _ = try await pi.send("tools:0 last", operationID: last, from: running)
        _ = try await pi.queue(.delete(id: first), from: running)
        try await eventually("both yield requests") { actions(pi).count == 2 }
        #expect(actions(pi) == ["yield", "yield"], "a remaining row still owns the yield")
        _ = try await pi.queue(clear ? .clear : .delete(id: last), from: running)
        try await eventually("unyield when the last row disappears") { actions(pi) == ["yield", "yield", "unyield"] }
        #expect(try await pi.snapshot().queue?.items.isEmpty == true)
        #expect(prompts(pi) == ["tools:1 build"])
        // Undo creates host input again and must yield again, rather than resurrecting a stranded row.
        _ = try await pi.queue(.restore(ids: [last], index: 0), from: running)
        try await eventually("the restored row to yield") { actions(pi).last == "yield" && actions(pi).count == 4 }
        pi.finishTool(1)
        _ = try await pi.snapshot("the restored row answered") { !$0.running && $0.messages.contains { $0.operationID == last } }
        try await eventually("the restored row to release its yield") { actions(pi).count == 5 }
        #expect(actions(pi).last == "unyield")
        #expect(prompts(pi) == ["tools:1 build", "tools:0 last"])
    }

    @Test(arguments: ["/session-name report command consumed", "please refuse"])
    func aSteerThatLeavesNoPendingRowUnyields(text: String) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        let result = try await pi.send(text, delivery: .steer, from: running)
        #expect(result.failureCode == (text == "please refuse" ? "dispatch_failed" : nil))
        try await eventually("the consumed or refused steer to unyield") { actions(pi) == ["yield", "unyield"] }
        #expect(try await pi.snapshot().queue?.items.isEmpty == true)
        #expect(prompts(pi) == ["tools:1 build", text])
        pi.finishTool(1)
        _ = try await pi.snapshot("the original turn settled") { !$0.running }
        #expect(prompts(pi) == ["tools:1 build", text], "nothing is stranded or sent twice")
    }

    @Test func aSteeringRowKeepsTheGoalYieldUntilPiReadsIt() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        let id = UUID()
        _ = try await pi.send("tools:0 turn left", delivery: .steer, operationID: id, from: running)
        _ = try await pi.snapshot("pi's pending steer") { $0.queue?.items.first?.state == .steering }
        #expect(actions(pi) == ["yield"], "a pending steer still owns the yield")
        pi.finishTool(1)
        let done = try await pi.snapshot("the steer read and answered") { !$0.running && $0.messages.contains { $0.operationID == id } }
        try await eventually("the landed steer to unyield") { actions(pi) == ["yield", "unyield"] }
        #expect(done.messages.first { $0.operationID == id }?.origin == .steered)
        #expect(prompts(pi) == ["tools:1 build", "tools:0 turn left"])
    }

    @Test func aRefusedQueuedSteerKeepsYieldingUntilItsFallbackRowIsDeleted() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        let id = UUID()
        _ = try await pi.send("please refuse", operationID: id, from: running)
        _ = try await pi.queue(.steer(ids: [id]), from: running)
        _ = try await pi.snapshot("the steer refusal returned to the queue") { $0.queue?.items.first?.state == .queued && $0.queue?.notice != nil }
        #expect(actions(pi) == ["yield"])
        _ = try await pi.queue(.delete(id: id), from: running)
        try await eventually("the fallback's deletion to unyield") { actions(pi) == ["yield", "unyield"] }
    }

    @Test(arguments: [NativeGoalState.working, .checking])
    func stopPausesTheControllerBeforeClearingAndAbortingWithoutWakingTheGoal(state: NativeGoalState) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        _ = try await publish(goal(state), to: pi)
        let id = UUID()
        _ = try await pi.send("tools:0 waiting", operationID: id, from: running)
        _ = try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID()))
        let stopped = try await pi.snapshot("the stopped goal and paused queue") { !$0.running && $0.goal?.state == .paused && $0.queue?.paused == true }
        let rows = pi.stdin()
        let pause = try #require(rows.firstIndex { ($0["message"] as? String)?.contains("\"pause\"") == true })
        let clear = try #require(rows.firstIndex { $0["type"] as? String == "clear_queue" })
        let abort = try #require(rows.firstIndex { $0["type"] as? String == "abort" })
        #expect(pause < clear && clear < abort)
        #expect(stopped.queue?.items.map(\.id) == [id])
        _ = try await pi.queue(.delete(id: id), from: stopped)
        _ = try await pi.snapshot()
        #expect(actions(pi) == ["yield", "pause"])
        #expect(prompts(pi) == ["tools:1 build"])
    }

    @Test(arguments: [NativeGoalState.working, .checking], [false, true])
    func steerNowPausesTheControllerBeforeAbortAndStillDeliversTheUsersMessage(state: NativeGoalState, queued: Bool) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        _ = try await publish(goal(state), to: pi)
        let id = UUID()
        #expect(try await pi.queue(.interrupt(ids: [UUID()]), from: running).failureCode == "queue_item_unavailable")
        #expect(actions(pi).isEmpty, "an unavailable row cannot pause the goal")
        if queued {
            _ = try await pi.send("tools:0 instead", operationID: id, from: running)
            _ = try await pi.queue(.interrupt(ids: [id]), from: running)
        } else {
            _ = try await pi.send("tools:0 instead", delivery: .interrupt, operationID: id, from: running)
        }
        let done = try await pi.snapshot("the interrupting message answered with a paused goal") { s in
            !s.running && s.goal?.state == .paused && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == id }
        }
        let rows = pi.stdin()
        let interrupt = try #require(rows.firstIndex { ($0["message"] as? String)?.contains("\"interrupt\"") == true })
        let clear = try #require(rows.firstIndex { $0["type"] as? String == "clear_queue" })
        let abort = try #require(rows.firstIndex { $0["type"] as? String == "abort" })
        #expect(interrupt < clear && clear < abort)
        #expect(actions(pi) == (queued ? ["yield", "interrupt"] : ["interrupt"]))
        #expect(prompts(pi) == ["tools:1 build", "tools:0 instead"])
        let delivered = try #require(done.messages.first { $0.operationID == id })
        if queued { #expect(delivered.origin?.parts?.map(\.id) == [id]) }
        else { #expect(delivered.origin == nil) }
    }

    @Test func aSessionChangeDropsTheOldQueuesGoalYield() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await launch(host)
        let running = try await start(pi)
        _ = try await pi.send("newsession", from: running)
        pi.finishTool(1)
        let switched = try await pi.snapshot("the new session") { $0.generation != running.generation && $0.goal == nil }
        var next = goal(.working)
        next.id = UUID().uuidString
        _ = try await publish(next, to: pi)
        _ = try await pi.queue(.clear, from: switched)
        _ = try await pi.snapshot()
        #expect(actions(pi) == ["yield"], "the old session's yield cannot wake this goal")
        #expect(prompts(pi) == ["tools:1 build", "newsession"])
    }
}

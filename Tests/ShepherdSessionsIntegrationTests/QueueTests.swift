import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The queue the host holds while pi works (`RPCThreadState+Queue`), against the stub's model of
/// pi 0.87.1's queues: a "tools:N" run makes N tool calls, each waiting for `finishTool(k)`,
/// takes steering after each batch and follow-ups when it would stop. Queued texts carry
/// "tools:0" so the run they open is the stub's pi-like one.
@Suite("Queue and steer", .integrationTimeLimit)
struct QueueTests {
    /// Starts a "tools:N" run and returns the snapshot once its first call is running.
    private func startRun(_ pi: PiAgent, _ prompt: String = "tools:1 build") async throws -> NativeThreadSnapshot {
        _ = try await pi.send(prompt, from: try await pi.ready())
        return try await pi.snapshot("the first tool call to run") { s in
            s.running && s.provisional.contains { $0.toolCallID != nil && $0.status == "running" }
        }
    }

    private func prompts(_ pi: PiAgent) -> [String] {
        pi.stdin("prompt").compactMap { $0["message"] as? String }
    }

    // MARK: - Delivery

    /// The reported bug's other half: a follow-up is not pi's until pi settles, and then it
    /// joins the thread where pi read it, with where it came from.
    @Test func aFollowUpWaitsOnTheHostAndGoesWhenPiSettles() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        #expect(running.provisional.first?.role == "user" && running.provisional.first?.entryID.hasPrefix("user:") == true,
                "the prompt is in the run, with pi's id, before the run ends")

        let op = UUID()
        #expect(try await pi.send("tools:0 and then tests", operationID: op, from: running) == .accepted(operationID: op))
        let queued = try await pi.snapshot("the follow-up in the queue") { $0.queue?.items.map(\.id) == [op] }
        let item = try #require(queued.queue?.items.first)
        #expect(item.state == .queued && item.text == "tools:0 and then tests" && item.sentAt > 0)
        #expect(prompts(pi) == ["tools:1 build"], "nothing reached pi")

        pi.finishTool(1)
        let done = try await pi.snapshot("the queue to go and its reply to settle") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.last?.role == "assistant"
                && s.messages.contains { $0.operationID == op }
        }
        #expect(prompts(pi) == ["tools:1 build", "tools:0 and then tests"])
        let delivered = try #require(done.messages.first { $0.operationID == op })
        #expect(delivered.origin == .queue(parts: [NativeQueuePart(id: op, text: "tools:0 and then tests", sentAt: item.sentAt)]))
        #expect(done.messages.suffix(2).map(\.role) == ["user", "assistant"], "answered, not left at the tail")
        #expect(done.provisional.isEmpty)
    }

    /// All at once (the default): the queue reaches pi as one message, so pi runs one turn for
    /// it, and the message keeps each part with its own send time.
    @Test func everythingAtOnceArrivesAsOneTurnInOrder() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let ops = [UUID(), UUID(), UUID()]
        for (op, text) in zip(ops, ["tools:0 one", "two", "three"]) {
            _ = try await pi.send(text, operationID: op, from: running)
        }
        let queued = try await pi.snapshot { $0.queue?.items.count == 3 }
        pi.finishTool(1)
        let done = try await pi.snapshot("the joined delivery to settle") { s in
            !s.running && s.messages.last?.role == "assistant" && s.messages.contains { $0.origin?.parts?.count == 3 }
        }
        #expect(prompts(pi) == ["tools:1 build", "tools:0 one\n\ntwo\n\nthree"])
        let delivered = try #require(done.messages.first { $0.origin?.parts?.count == 3 })
        #expect(delivered.origin?.parts?.map(\.id) == ops.map { Optional($0) })
        #expect(delivered.origin?.parts?.map(\.text) == ["tools:0 one", "two", "three"])
        #expect(delivered.origin?.parts?.map(\.sentAt) == queued.queue?.items.map(\.sentAt))
        let index = try #require(done.messages.firstIndex(of: delivered))
        #expect(done.messages[(index + 1)...].map(\.role) == ["assistant"], "one reply: one turn")
    }

    @Test func oneAtATimeSendsTheHeadEachTimePiSettles() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        #expect(try await pi.queue(.setMode(mode: .oneAtATime), from: running).failureCode == nil)
        _ = try await pi.send("tools:0 first", from: running)
        _ = try await pi.send("tools:0 second", from: running)
        let queued = try await pi.snapshot { $0.queue?.items.count == 2 }
        #expect(queued.queue?.mode == .oneAtATime)
        pi.finishTool(1)
        _ = try await pi.snapshot("both to go, one turn each") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.filter { $0.origin?.parts?.count == 1 }.count == 2
        }
        #expect(prompts(pi) == ["tools:1 build", "tools:0 first", "tools:0 second"])
    }

    /// An older Mac finds its sends in the thread by the text it sent, so its queued messages go
    /// to pi one per turn, each as sent, even all at once; a current client's still go together.
    @Test func anOlderClientsQueuedMessagesGoOnePerTurnAsSent() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host)
        let running = try await startRun(pi)
        let older = try await remote.raw()
        let current = try RawRemote(port: remote.port)
        try await current.hello(token: remote.token, capabilities: RemoteProtocol.clientCapabilities)
        var nextID = 0
        func send(_ text: String, from client: RawRemote) async throws {
            nextID += 1
            let id = nextID
            try client.send(.nativeThread(id: id, agentID: pi.agent.id, request: .send(
                expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID(), text: text, delivery: .followUp)))
            let reply = try await client.frames { frame in
                if case .nativeThread(id, _) = frame { true } else { false }
            }.last
            guard case .nativeThread(_, .accepted)? = reply else { throw WireError("send refused: \(String(describing: reply))") }
        }
        try await send("tools:0 old one", from: older)
        try await send("tools:0 old two", from: older)
        try await send("tools:0 new one", from: current)
        try await send("tools:0 new two", from: current)
        let queued = try await pi.snapshot { $0.queue?.items.count == 4 }
        #expect(queued.queue?.mode == .all)

        pi.finishTool(1)
        _ = try await pi.snapshot("the last message to be answered") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.last?.role == "assistant"
                && s.messages.contains { $0.origin?.parts?.contains { $0.text == "tools:0 new two" } == true }
        }
        #expect(prompts(pi) == ["tools:1 build", "tools:0 old one", "tools:0 old two", "tools:0 new one\n\ntools:0 new two"])
    }

    /// pi runs a command or expands a template only at the start of a message: such an item
    /// goes alone, and the items after it wait for the next delivery.
    @Test func aCommandInTheQueueGoesAlone() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        for text in ["tools:0 a", "/fix-tests now", "tools:0 b"] { _ = try await pi.send(text, from: running) }
        _ = try await pi.snapshot { $0.queue?.items.count == 3 }
        pi.finishTool(1)
        try await eventually("every delivery") { prompts(pi).count == 4 }
        #expect(prompts(pi) == ["tools:1 build", "tools:0 a", "/fix-tests now", "tools:0 b"])
    }

    // MARK: - Steering

    /// A steer goes to pi as a steer, shows as steering until pi reads it, and lands where pi
    /// read it: after the tool call it was waiting on, marked steered.
    @Test func aSteerLandsWherePiReadsIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi, "tools:2 build")
        let op = UUID()
        #expect(try await pi.send("tools:0 turn left", delivery: .steer, operationID: op, from: running) == .accepted(operationID: op))
        let steer = try await pi.waitForStdin("prompt", count: 2)
        #expect(steer["message"] as? String == "tools:0 turn left" && steer["streamingBehavior"] as? String == "steer")
        let steering = try await pi.snapshot { $0.queue?.items.first?.state == .steering }
        #expect(steering.queue?.items.map(\.id) == [op])

        pi.finishTool(1)
        let done = try await pi.snapshot("the steer to land and the run to settle") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.origin == .steered }
        }
        let tool = try #require(done.messages.firstIndex { $0.toolCallID == "call_q1" })
        #expect(done.messages[tool + 1].origin == .steered && done.messages[tool + 1].operationID == op,
                "right after the call it waited on")
        #expect(prompts(pi) == ["tools:2 build", "tools:0 turn left"], "landed, so nothing was sent again")
    }

    /// Back to the queue before pi reads it: pi's queue is cleared, the item returns to the
    /// head as queued, and every other steer is handed back to pi.
    @Test func backToTheQueueBeforePiReadsIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let back = UUID(), other = UUID()
        _ = try await pi.send("tools:0 wait", delivery: .steer, operationID: back, from: running)
        _ = try await pi.send("tools:0 other", delivery: .steer, operationID: other, from: running)
        _ = try await pi.snapshot("both steering") { $0.queue?.items.filter { $0.state == .steering }.count == 2 }

        #expect(try await pi.queue(.unsteer(id: back), from: running).failureCode == nil)
        let after = try await pi.snapshot { $0.queue?.items.map(\.state) == [.steering, .queued] }
        #expect(after.queue?.items.map(\.id) == [other, back])
        _ = try await pi.waitForStdin("clear_queue")
        _ = try await pi.waitForStdin("prompt", count: 4)
        #expect(prompts(pi) == ["tools:1 build", "tools:0 wait", "tools:0 other", "tools:0 other"], "the other steer was handed back")

        pi.finishTool(1)
        let done = try await pi.snapshot("the other to land and the returned one to go after") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == back }
        }
        #expect(done.messages.first { $0.operationID == other }?.origin == .steered)
        #expect(done.messages.first { $0.operationID == back }?.origin?.parts?.map(\.id) == [back])
    }

    /// pi reads a steer when its tool batch ends: a Back to the queue whose `clear_queue` arrives
    /// just after that finds nothing to take back, so it is refused, and the message lands where
    /// pi read it, steered, without being sent again.
    @Test func backToTheQueueJustAfterPiReadItIsRefused() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let op = UUID()
        _ = try await pi.send("tools:0 raced", delivery: .steer, operationID: op, from: running)
        _ = try await pi.snapshot { $0.queue?.items.first?.state == .steering }

        #expect(try await pi.queue(.unsteer(id: op), from: running).failureCode == "queue_item_unavailable")
        let after = try await pi.snapshot()
        #expect(after.queue?.items.map(\.id) == [op] && after.queue?.items.first?.state == .steering, "still pi's to land")

        pi.finishTool(1)
        let done = try await pi.snapshot("the steer to land") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == op }
        }
        #expect(done.messages.first { $0.operationID == op }?.origin == .steered)
        #expect(prompts(pi) == ["tools:1 build", "tools:0 raced"], "nothing was sent again")
    }

    @Test func backToTheQueueAfterPiReadItChangesNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let op = UUID()
        _ = try await pi.send("tools:0 now", delivery: .steer, operationID: op, from: running)
        _ = try await pi.snapshot { $0.queue?.items.first?.state == .steering }
        pi.finishTool(1)
        let done = try await pi.snapshot("the steer to land") { s in !s.running && s.messages.contains { $0.operationID == op } }
        #expect(try await pi.queue(.unsteer(id: op), from: done).failureCode == "queue_item_unavailable")
        #expect(pi.stdin("clear_queue").isEmpty)
    }

    /// A steer pi queued after its last look at its queue is stranded there when it settles:
    /// the host takes it back and sends it next, so it is neither lost nor left for a later run.
    @Test func aStrandedSteerIsTakenBackAndSentWhenPiSettles() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:0 hold-settle", from: try await pi.ready())
        let held = try await pi.snapshot("the reply, before the run settles") { s in
            s.running && s.provisional.contains { $0.role == "assistant" && $0.status == "stop" }
        }
        let op = UUID()
        _ = try await pi.send("tools:0 late", delivery: .steer, operationID: op, from: held)
        _ = try await pi.waitForStdin("prompt", count: 2)
        pi.releaseSettle()
        let done = try await pi.snapshot("the stranded steer to go as the next turn") { s in
            !s.running && s.messages.contains { $0.operationID == op }
        }
        let last = try await pi.waitForStdin("prompt", count: 3)
        #expect(last["message"] as? String == "tools:0 late" && last["streamingBehavior"] as? String == "followUp")
        #expect(pi.stdin().firstIndex { $0["type"] as? String == "clear_queue" } != nil)
        #expect(done.messages.first { $0.operationID == op }?.origin?.parts?.map(\.id) == [op])
    }

    // MARK: - Stop

    /// Stop: pi's queue is cleared before the abort (pi's recipe; abort alone still delivers a
    /// queued steer), the steer returns to the head of the queue, and the queue waits.
    @Test func stopClearsPisQueueFirstAndPausesTheQueue() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let follow = UUID(), steer = UUID()
        _ = try await pi.send("tools:0 after", operationID: follow, from: running)
        _ = try await pi.send("tools:0 instead", delivery: .steer, operationID: steer, from: running)
        _ = try await pi.snapshot { $0.queue?.items.count == 2 }

        #expect(try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID())).failureCode == nil)
        let types = pi.stdin().compactMap { $0["type"] as? String }
        let clear = try #require(types.firstIndex(of: "clear_queue"))
        let abort = try #require(types.firstIndex(of: "abort"))
        #expect(clear < abort)
        // pi ends a run stopped mid-tool-call with an error reply (the stub does too).
        let stopped = try await pi.snapshot("the run to end in an error reply") { s in
            !s.running && s.messages.last { $0.role == "assistant" }?.status == "error"
        }
        #expect(stopped.queue?.items.map(\.id) == [steer, follow] && stopped.queue?.items.allSatisfy { $0.state == .queued } == true)
        #expect(stopped.queue?.paused == true)
        #expect(stopped.queue?.notice == nil, "the queue waits because of the stop, not a turn that failed")
        #expect(!stopped.messages.contains { $0.operationID == steer }, "the steer did not land in the stopped run")
        #expect(prompts(pi).count == 2, "a stopped queue waits")

        // Send now resumes it: that message opens the next turn, and the rest follows.
        #expect(try await pi.queue(.sendNow(ids: [follow]), from: stopped).failureCode == nil)
        _ = try await pi.snapshot("both to go") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == steer }
        }
        #expect(prompts(pi).suffix(2) == ["tools:0 after", "tools:0 instead"])
    }

    @Test func aHeldItemKeepsTheQueueWaitingUntilItsEditorCloses() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let op = UUID()
        _ = try await pi.send("tools:0 draft", operationID: op, from: running)
        #expect(try await pi.queue(.hold(id: op, held: true), from: running).failureCode == nil)
        pi.finishTool(1)
        let settled = try await pi.snapshot("the run to settle") { !$0.running }
        #expect(settled.queue?.items.first?.held == true)
        #expect(prompts(pi).count == 1)
        #expect(try await pi.queue(.edit(id: op, text: "tools:0 final"), from: settled).failureCode == nil, "saving closes the editor")
        _ = try await pi.waitForStdin("prompt", count: 2)
        #expect(prompts(pi).last == "tools:0 final")
    }

    @Test func aDeliveryPiRefusesComesBackAndPausesTheQueue() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let op = UUID()
        _ = try await pi.send("please refuse", operationID: op, from: running)
        pi.finishTool(1)
        let paused = try await pi.snapshot("the refusal") { $0.queue?.paused == true }
        #expect(paused.queue?.items.map(\.id) == [op])
        #expect(paused.queue?.notice?.contains("refused by the stub") == true)
        #expect(!paused.provisional.contains { $0.entryID == "pending:\(op.uuidString)" }, "no row is left for it")
    }

    /// After a stop, a newly typed message goes at once, and the waiting queue follows it.
    @Test func aNewMessageAfterAStopGoesAtOnceAndTheQueueFollows() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let waiting = UUID(), fresh = UUID()
        _ = try await pi.send("tools:0 waiting", operationID: waiting, from: running)
        _ = try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID()))
        let stopped = try await pi.snapshot("the stop") { !$0.running && $0.queue?.paused == true }
        #expect(try await pi.send("tools:0 fresh", operationID: fresh, from: stopped) == .accepted(operationID: fresh))
        _ = try await pi.snapshot("both to go, the new one first") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == waiting }
        }
        #expect(prompts(pi).suffix(2) == ["tools:0 fresh", "tools:0 waiting"])
    }

    /// Agents follow the host's mode (Settings) until they choose their own.
    @Test func theHostDefaultModeAppliesUntilAnAgentChoosesItsOwn() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        h.server.setDefaultQueueMode(.oneAtATime)
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.snapshot("the agent to serve with the host's mode") { !$0.piSessionID.isEmpty && $0.queue?.mode == .oneAtATime }
        #expect(try await pi.queue(.setMode(mode: .all), from: s).failureCode == nil)
        #expect(try await pi.snapshot().queue?.mode == .all)
        h.server.setDefaultQueueMode(.oneAtATime)
        #expect(try await pi.snapshot().queue?.mode == .all, "the agent's own choice wins")
        #expect(try await pi.queue(.setMode(mode: nil), from: s).failureCode == nil)
        #expect(try await pi.snapshot().queue?.mode == .oneAtATime, "back to the host's")
        h.server.setDefaultQueueMode(.all)
        _ = try await pi.snapshot("the host's new default") { $0.queue?.mode == .all }
    }

    // MARK: - Editing

    @Test func editMoveDeleteRestoreAndClearChangeTheQueueInPlace() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await startRun(pi)
        let a = UUID(), b = UUID(), c = UUID()
        for (op, text) in [(a, "tools:0 a"), (b, "b"), (c, "tools:0 c")] { _ = try await pi.send(text, operationID: op, from: s) }
        func ids() async throws -> [UUID] { try await pi.snapshot().queue?.items.map(\.id) ?? [] }

        #expect(try await pi.queue(.edit(id: b, text: "b!"), from: s).failureCode == nil)
        #expect(try await pi.snapshot().queue?.items.map(\.text) == ["tools:0 a", "b!", "tools:0 c"])
        #expect(try await pi.queue(.move(id: c, index: 0), from: s).failureCode == nil)
        #expect(try await ids() == [c, a, b])
        #expect(try await pi.queue(.delete(id: a), from: s).failureCode == nil)
        #expect(try await ids() == [c, b])
        #expect(try await pi.queue(.restore(ids: [a], index: 1), from: s).failureCode == nil)
        #expect(try await ids() == [c, a, b])
        #expect(try await pi.queue(.clear, from: s).failureCode == nil)
        #expect(try await ids() == [])
        #expect(try await pi.queue(.restore(ids: [c, a, b], index: 0), from: s).failureCode == nil)
        #expect(try await ids() == [c, a, b])

        #expect(try await pi.queue(.edit(id: UUID(), text: "x"), from: s).failureCode == "queue_item_unavailable")
        #expect(try await pi.queue(.edit(id: a, text: "  "), from: s).failureCode == "invalid")
        #expect(prompts(pi) == ["tools:1 build"], "editing never reaches pi")

        pi.finishTool(1)
        _ = try await pi.waitForStdin("prompt", count: 2)
        #expect(prompts(pi).last == "tools:0 c\n\ntools:0 a\n\nb!", "delivered in the queue's order")
    }

    /// Another client (a remote Mac) sees and changes the same queue.
    @Test func aRemoteClientEditsTheSameQueue() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host)
        let s = try await startRun(pi)
        let a = UUID(), b = UUID()
        _ = try await pi.send("tools:0 a", operationID: a, from: s)
        _ = try await pi.send("tools:0 b", operationID: b, from: s)
        let client = try await r.typed()
        defer { client.disconnect() }

        guard case .snapshot(let remote) = try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()) else {
            Issue.record("expected a snapshot"); return
        }
        #expect(remote.queue?.items.map(\.id) == [a, b])
        let op = UUID()
        let moved = try await client.nativeThread(agentID: pi.agent.id, request: .queue(
            expectedSessionID: remote.piSessionID, generation: remote.generation, operationID: op, action: .move(id: b, index: 0)))
        #expect(moved == .accepted(operationID: op))
        #expect(try await pi.snapshot().queue?.items.map(\.id) == [b, a], "the host's queue, for every client")
    }

    // MARK: - Lifetimes

    /// pi exiting mid-run takes its queue with it: the thread is unavailable, and nothing is
    /// left waiting on a pi that is gone.
    @Test func piExitingWithAQueueLeavesTheThreadUnavailable() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        let s = try await startRun(pi)
        _ = try await pi.send("tools:0 queued", from: s)
        _ = try? await pi.send("die", delivery: .steer, from: s)
        try await eventually("the exit") { callbacks.exited(pi.sessionID) }
        let error = await #expect(throws: RemoteHostClientError.self) { _ = try await pi.request(.snapshot()) }
        guard case .rejected("native_unavailable", _)? = error else { Issue.record("expected native_unavailable, got \(String(describing: error))"); return }
    }

    /// Between queued turns pi settles for a moment; the agent is not done (no "Agent finished")
    /// while its queue goes next, and is once the queue is empty.
    @Test func theAgentStaysWorkingWhileItsQueueGoes() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        let status = try ExtensionClient(path: h.socketPath)
        defer { status.closeConnection() }
        func agentStatus() -> AgentStatus? { h.server.state.agents.first { $0.id == pi.agent.id }?.status }
        func reports() -> [AgentStatus] { callbacks.statuses.current.filter { $0.0 == pi.agent.id }.map(\.1) }
        let s = try await startRun(pi)
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .working))
        try await eventually("working") { agentStatus() == .working }
        _ = try await pi.send("tools:0 next", from: s)
        _ = try await pi.snapshot { $0.queue?.items.count == 1 }

        let seen = reports().count
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .done))
        // Behind it on the same connection: once this one is reported, the one above was read.
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .working))
        try await eventually("the reports to be read") { reports().count > seen }
        #expect(Array(reports()[seen...]) == [.working], "done was held: the queue goes next")
        #expect(agentStatus() == .working)

        pi.finishTool(1)
        _ = try await pi.snapshot("the queue to go") { s in !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.origin != nil } }
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .done))
        try await eventually("done once the queue is empty") { agentStatus() == .done }
    }

    /// Where a message came from outlives the app: after a relaunch the thread still shows the
    /// queue's parts with their own send times (pi's session holds only the joined message).
    @Test func originsSurviveARelaunch() async throws {
        let dir = try makeScratchDirectory("relaunch")
        let messages = dir.appendingPathComponent("pi-session.json").path
        var h = try ScratchServer(dir: dir)
        var pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": messages])
        let s = try await startRun(pi)
        let a = UUID(), b = UUID()
        _ = try await pi.send("tools:0 one", operationID: a, from: s)
        _ = try await pi.send("two", operationID: b, from: s)
        let queued = try await pi.snapshot { $0.queue?.items.count == 2 }
        pi.finishTool(1)
        let before = try await pi.snapshot("the delivery to settle") { s in !s.running && s.messages.contains { $0.origin?.parts?.count == 2 } }
        let delivered = try #require(before.messages.first { $0.origin?.parts?.count == 2 })
        h.stop(keepFiles: true)

        h = try ScratchServer(dir: dir)
        defer { h.stop() }
        pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": messages])
        let after = try await pi.snapshot("the resumed history") { s in s.messages.contains { $0.entryID == delivered.entryID } }
        let resumed = try #require(after.messages.first { $0.entryID == delivered.entryID })
        #expect(resumed.origin?.parts?.map(\.id) == [a, b])
        #expect(resumed.origin?.parts?.map(\.sentAt) == queued.queue?.items.map(\.sentAt))
        #expect(resumed.blocks.first?.text == "tools:0 one\n\ntwo", "pi's own message is the joined text")
    }
}

/// The reported bug, end to end: a message whose run adds more than a page of history must
/// not stay drawn at the tail after later replies. The host now shows pi's user message where
/// pi read it, and the store drops its echo at the host's next snapshot instead of waiting to
/// find the text on the newest page.
@Suite("Queue and steer in the store", .mainActorExclusive)
@MainActor
struct QueueStoreTests {
    @Test func aMessageAnsweredBeyondAPageIsNeverLeftAtTheTail() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        // Every call of the run may finish at once: 30 calls put the prompt 61 entries back.
        for k in 1...30 { pi.finishTool(k) }
        // Polls quickly, as the app's store does while a run streams.
        let store = NativeThreadStore { _ in try await Task.sleep(for: .milliseconds(20)) }
        let task = Task { await store.run { try await pi.request($0) } }
        defer { task.cancel() }
        try await eventuallyOnMain("the thread to load") { store.ready }

        store.draft = "tools:30 ye"
        await store.send()
        try await eventuallyOnMain("the run to settle") {
            store.snapshot?.running == false && store.messages.last?.role == "assistant" && store.olderCursor != nil
        }
        #expect(store.pending.isEmpty)
        #expect(store.displayedMessages.last?.role == "assistant")
        #expect(!store.displayedMessages.contains { $0.role == "user" && $0.blocks.first?.text == "tools:30 ye" },
                "the prompt is on an older page now, not drawn at the tail")
    }
}

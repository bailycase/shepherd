import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Sending while pi works: steering at pi's next step (the default), and Steer now, which stops
/// pi as Stop does and sends the message at once as the next turn (`RPCThreadState+Interrupt`).
/// Against the stub's model of pi 0.87.1 (see `stub-pi.py`, and `Tests/Extensions/
/// steer-interrupt.test.mjs` for the real thing): a "tools:N" run makes N tool calls, each waiting
/// for `finishTool(k)`; an abort fails the running call and ends the run, its answer coming after
/// `agent_settled`, as pi's does.
@Suite("Steer now", .integrationTimeLimit)
struct InterruptTests {
    private func startRun(_ pi: PiAgent, _ prompt: String = "tools:1 build") async throws -> NativeThreadSnapshot {
        _ = try await pi.send(prompt, from: try await pi.ready())
        return try await pi.snapshot("the first tool call to run") { s in
            s.running && s.provisional.contains { $0.toolCallID != nil && $0.status == "running" }
        }
    }

    private func prompts(_ pi: PiAgent) -> [String] {
        pi.stdin("prompt").compactMap { $0["message"] as? String }
    }

    private func types(_ pi: PiAgent) -> [String] {
        pi.stdin().compactMap { $0["type"] as? String }
    }

    /// pi's side of the store test, off the main actor.
    static func waitForATool(_ pi: PiAgent) async throws {
        _ = try await pi.send("tools:2 build", from: try await pi.ready())
        _ = try await pi.snapshot("a tool call to run") { s in s.running && s.provisional.contains { $0.toolCallID != nil && $0.status == "running" } }
    }

    static func waitForTheMessageToRun(_ pi: PiAgent, text: String) async throws {
        _ = try await pi.snapshot("the message to run as a new turn") { s in
            !s.running && s.messages.contains { $0.role == "user" && $0.blocks.first?.text == text }
        }
    }

    static func prompts(_ pi: PiAgent, count: Int) async throws -> [[String: Any]] {
        try await eventually("\(count) prompts") { pi.stdin("prompt").count >= count }
        return pi.stdin("prompt")
    }

    private func touch(_ host: ScratchServer, _ name: String) {
        FileManager.default.createFile(atPath: host.dir.appendingPathComponent(name).path, contents: nil)
    }

    // MARK: - Steering is the default way in

    /// Several messages sent in a row while pi works each steer, land one per step in the order
    /// they were sent, and every one exactly once, all in the run they were sent to.
    @Test func severalSteersInARowLandInOrderAfterTheToolCall() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let ops = [UUID(), UUID(), UUID()]
        for (op, text) in zip(ops, ["tools:0 one", "tools:0 two", "tools:0 three"]) {
            #expect(try await pi.send(text, delivery: .steer, operationID: op, from: running) == .accepted(operationID: op))
        }
        let steering = try await pi.snapshot("three Steering rows") { $0.queue?.items.filter { $0.state == .steering }.count == 3 }
        #expect(steering.queue?.items.map(\.id) == ops, "in the order they were steered")
        #expect(prompts(pi) == ["tools:1 build", "tools:0 one", "tools:0 two", "tools:0 three"], "each handed to pi at once")

        pi.finishTool(1)
        let done = try await pi.snapshot("all three to land and the run to settle") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.filter { $0.origin == .steered }.count == 3
        }
        #expect(done.messages.filter { $0.origin == .steered }.map(\.operationID) == ops.map { Optional($0) })
        #expect(prompts(pi).count == 4, "landed, so nothing was sent again")
        #expect(pi.stdin("clear_queue").isEmpty && pi.stdin("abort").isEmpty)
    }

    /// Steers pi is holding at the end of a run (it read its queue for the last time before they
    /// arrived) are taken back and go as the next turn: none lost, none doubled.
    @Test func severalStrandedSteersAreTakenBackAndSentAsTheNextTurn() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:0 hold-settle", from: try await pi.ready())
        let held = try await pi.snapshot("the reply, before the run settles") { s in
            s.running && s.provisional.contains { $0.role == "assistant" && $0.status == "stop" }
        }
        let a = UUID(), b = UUID()
        _ = try await pi.send("tools:0 late a", delivery: .steer, operationID: a, from: held)
        _ = try await pi.send("tools:0 late b", delivery: .steer, operationID: b, from: held)
        _ = try await pi.waitForStdin("prompt", count: 3)
        pi.releaseSettle()
        let done = try await pi.snapshot("the stranded steers to go as the next turn") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.origin?.parts?.count == 2 }
        }
        let next = try #require(done.messages.first { $0.origin?.parts?.count == 2 })
        #expect(next.origin?.parts?.map(\.id) == [a, b], "in the order they were sent")
        #expect(prompts(pi).last == "tools:0 late a\n\ntools:0 late b")
        #expect(prompts(pi).filter { $0.contains("late") }.count == 3, "each steer once, then the two together")
    }

    /// A steer sent while a question waits is pi's queue's, and lands or goes next as any other.
    @Test func aSteerSentWhileAQuestionWaitsIsNotLost() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("question", from: try await pi.ready())
        let asking = try await pi.snapshot("pi to ask") { !$0.dialogs.isEmpty }
        let op = UUID()
        #expect(try await pi.send("tools:0 while you wait", delivery: .steer, operationID: op, from: asking) == .accepted(operationID: op))
        let dialog = try #require(asking.dialogs.first)
        let option = try #require(dialog.options?.first)
        #expect(try await pi.request(.answer(expectedSessionID: asking.piSessionID, generation: asking.generation, operationID: UUID(),
                                             dialogID: dialog.id, answer: .select(value: option))).failureCode == nil)
        let done = try await pi.snapshot("the message to run after the question's turn") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == op }
                && s.messages.last?.role == "assistant"
        }
        #expect(done.messages.filter { $0.operationID == op }.count == 1)
        #expect(prompts(pi).filter { $0.contains("while you wait") }.count >= 1)
    }

    /// Stop with several Steering rows takes every one back, in order, and pauses the queue.
    @Test func stopReturnsEverySteeringRowInOrder() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi, "tools:2 build")
        let ops = [UUID(), UUID(), UUID()]
        // Two of them say the same, as people do.
        for (op, text) in zip(ops, ["tools:0 again", "tools:0 other", "tools:0 again"]) {
            _ = try await pi.send(text, delivery: .steer, operationID: op, from: running)
        }
        _ = try await pi.snapshot("three Steering rows") { $0.queue?.items.filter { $0.state == .steering }.count == 3 }

        #expect(try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID())).failureCode == nil)
        let stopped = try await pi.snapshot("the run to end in its reply to the stop") { s in
            !s.running && s.messages.last { $0.role == "assistant" }?.status == "aborted"
        }
        #expect(stopped.queue?.items.map(\.id) == ops && stopped.queue?.items.allSatisfy { $0.state == .queued } == true)
        #expect(stopped.queue?.paused == true)
        #expect(!stopped.messages.contains { $0.origin == .steered }, "none landed in the stopped run")
        #expect(prompts(pi).count == 4)
    }

    // MARK: - Steer now

    /// The composer's Steer now: pi's queue is cleared, pi is aborted, and only once it has
    /// answered does the message go, as a prompt of its own; it starts the next turn as an
    /// ordinary message, and the stopped turn reads as stopped.
    @Test func steerNowStopsTheRunAndSendsTheMessageAsTheNextTurn() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi, "tools:2 build")
        let op = UUID()
        #expect(try await pi.send("tools:0 do this instead", delivery: .interrupt, operationID: op, from: running) == .accepted(operationID: op))

        let done = try await pi.snapshot("the message to run as the next turn") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == op }
                && s.messages.last?.role == "assistant" && s.provisional.isEmpty
        }
        let order = types(pi)
        let clear = try #require(order.firstIndex(of: "clear_queue")), abort = try #require(order.firstIndex(of: "abort"))
        let send = try #require(order.lastIndex(of: "prompt"))
        #expect(clear < abort && abort < send, "pi's queue is cleared, then it is aborted, then the message goes")
        #expect(prompts(pi) == ["tools:2 build", "tools:0 do this instead"], "once: nothing lost, nothing doubled")
        #expect(pi.stdin("prompt").last?["streamingBehavior"] as? String == "followUp", "a plain prompt, not a steer")

        let tool = try #require(done.messages.first { $0.toolCallID == "call_q1" })
        #expect(tool.status == "aborted", "the call it stopped reads as stopped")
        #expect(done.messages.contains { $0.role == "assistant" && $0.status == "aborted" }, "the turn it ended reads as stopped, not as a failure")
        #expect(!done.messages.contains { $0.status == "error" })
        let message = try #require(done.messages.first { $0.operationID == op })
        #expect(message.role == "user" && message.origin == nil, "an ordinary message, not one from the queue")
        #expect(done.messages.suffix(2).map(\.role) == ["user", "assistant"])
        #expect(done.queue?.paused == false && done.queue?.notice == nil, "the queue never pauses for it")
        #expect(done.messages.filter { $0.blocks.first?.text.hasPrefix("tools:") == true }.count == 2, "the first message and the new one")
    }

    /// The rest of the queue carries on after the message, and the steers pi held go back behind
    /// it: they were taken out of pi's queue before the abort, so none lands in the stopped run.
    @Test func theRestOfTheQueueCarriesOnAfterSteerNow() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi, "tools:2 build")
        let later = UUID(), laterToo = UUID(), held = UUID(), now = UUID()
        _ = try await pi.send("tools:0 later a", operationID: later, from: running)
        _ = try await pi.send("tools:0 later b", operationID: laterToo, from: running)
        _ = try await pi.send("tools:0 held", delivery: .steer, operationID: held, from: running)
        _ = try await pi.snapshot("the held steer in pi's queue") { $0.queue?.items.first?.state == .steering && $0.queue?.items.count == 3 }
        _ = try await pi.waitForStdin("prompt", count: 2)

        #expect(try await pi.send("tools:0 now", delivery: .interrupt, operationID: now, from: running) == .accepted(operationID: now))
        let done = try await pi.snapshot("everything to go") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.origin?.parts?.count == 3 }
        }
        #expect(prompts(pi) == ["tools:2 build", "tools:0 held", "tools:0 now", "tools:0 held\n\ntools:0 later a\n\ntools:0 later b"],
                "the message alone and first, then what was waiting, as one turn, in order")
        let clear = pi.stdin("clear_queue")
        #expect(clear.count == 1)
        #expect(!done.messages.contains { $0.origin == .steered }, "the held steer did not land in the stopped run")
        let batch = try #require(done.messages.first { $0.origin?.parts?.count == 3 })
        #expect(batch.origin?.parts?.map(\.id) == [held, later, laterToo])
        let index = try #require(done.messages.firstIndex { $0.operationID == now })
        #expect(index < (done.messages.firstIndex(of: batch) ?? 0))
    }

    /// Up next's Steer now (a queued row) is the same interrupt, for the message it names: the
    /// rest of the queue keeps its order behind it.
    @Test func steerNowOnAQueuedRowSendsThatMessageFirst() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi, "tools:2 build")
        let a = UUID(), b = UUID(), c = UUID()
        for (id, text) in [(a, "tools:0 a"), (b, "tools:0 b"), (c, "tools:0 c")] { _ = try await pi.send(text, operationID: id, from: running) }
        _ = try await pi.snapshot { $0.queue?.items.count == 3 }
        #expect(try await pi.queue(.interrupt(ids: [c]), from: running).failureCode == nil)
        let done = try await pi.snapshot("everything to go") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.origin?.parts?.count == 2 }
        }
        #expect(prompts(pi) == ["tools:2 build", "tools:0 c", "tools:0 a\n\ntools:0 b"])
        #expect(done.messages.first { $0.operationID == c }?.origin?.parts?.map(\.id) == [c], "from the queue, like any queued message")
    }

    /// Steer now on several rows (Steer all now) sends them together, in order, as the next turn.
    @Test func steerAllNowSendsTheRowsTogetherInOrder() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi, "tools:2 build")
        let a = UUID(), b = UUID()
        _ = try await pi.send("tools:0 a", operationID: a, from: running)
        _ = try await pi.send("tools:0 b", operationID: b, from: running)
        _ = try await pi.snapshot { $0.queue?.items.count == 2 }
        #expect(try await pi.queue(.interrupt(ids: [a, b]), from: running).failureCode == nil)
        let done = try await pi.snapshot("both to go as one turn") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.origin?.parts?.count == 2 }
        }
        #expect(prompts(pi) == ["tools:2 build", "tools:0 a\n\ntools:0 b"])
        #expect(pi.stdin("abort").count == 1)
        #expect(done.messages.first { $0.origin?.parts?.count == 2 }?.origin?.parts?.map(\.id) == [a, b])
    }

    /// A second Steer now while pi is still stopping goes with the first: one abort, both
    /// messages once, in order.
    @Test func aSecondSteerNowWhilePiStopsGoesWithTheFirst() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let one = UUID(), two = UUID()
        touch(h, "clear-gate")
        _ = try await pi.send("tools:0 one", delivery: .interrupt, operationID: one, from: running)
        _ = try await pi.send("tools:0 two", delivery: .interrupt, operationID: two, from: running)
        touch(h, "clear-go")
        let done = try await pi.snapshot("both to run") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == one }
                && s.messages.contains { $0.origin?.parts?.map(\.id) == [one, two] }
        }
        #expect(pi.stdin("abort").count == 1)
        #expect(prompts(pi) == ["tools:1 build", "tools:0 one\n\ntools:0 two"])
        #expect(done.queue?.paused == false)
    }

    /// Images ride along.
    @Test func steerNowKeepsItsImages() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let image = NativeImage(mimeType: "image/png", data: Data([1, 2, 3]), name: "shot.png")
        let op = UUID()
        _ = try await pi.send("tools:0 look at this", delivery: .interrupt, images: [image], operationID: op, from: running)
        _ = try await pi.snapshot("the message to run") { s in !s.running && s.messages.contains { $0.operationID == op } }
        let sent = try #require(pi.stdin("prompt").last)
        #expect((sent["images"] as? [[String: Any]])?.first?["data"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    /// While pi is idle it is a plain send: nothing to stop.
    @Test func steerNowWhilePiIsIdleIsAPlainSend() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        let op = UUID()
        #expect(try await pi.send("tools:0 hello", delivery: .interrupt, operationID: op, from: idle) == .accepted(operationID: op))
        let done = try await pi.snapshot("the reply") { s in !s.running && s.messages.contains { $0.operationID == op } && s.messages.last?.role == "assistant" }
        #expect(pi.stdin("abort").isEmpty && pi.stdin("clear_queue").isEmpty)
        #expect(prompts(pi) == ["tools:0 hello"])
        #expect(done.queue?.items.isEmpty == true)
    }

    /// While pi is idle with a paused queue, Steer now on a row sends that message first and the
    /// rest resumes after it (the same as Send now).
    @Test func steerNowOnARowWhilePiIsIdleSendsItAndResumesTheQueue() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let a = UUID(), b = UUID()
        _ = try await pi.send("tools:0 a", operationID: a, from: running)
        _ = try await pi.send("tools:0 b", operationID: b, from: running)
        _ = try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID()))
        let stopped = try await pi.snapshot("the stop") { !$0.running && $0.queue?.paused == true }
        #expect(try await pi.queue(.interrupt(ids: [b]), from: stopped).failureCode == nil)
        _ = try await pi.snapshot("both to go, b first") { s in !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == a } }
        #expect(prompts(pi).suffix(2) == ["tools:0 b", "tools:0 a"])
        #expect(pi.stdin("abort").count == 1, "only Stop's own")
    }

    // MARK: - Where it falls back to a steer

    /// pi refuses a prompt while it compacts, and an abort would end the compaction: the message
    /// waits first in Up next and goes when pi settles. Nothing is aborted, nothing refused.
    @Test(arguments: [NativeThreadDelivery.interrupt, .steer])
    func duringACompactionTheMessageWaitsFirstAndGoesWhenPiSettles(delivery: NativeThreadDelivery) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await startRun(pi, "tools:1 compact-hold")
        pi.finishTool(1)
        let compacting = try await pi.snapshot("pi to compact") { s in s.running && s.provisional.contains { $0.compaction?.phase == .running } }
        let other = UUID(), op = UUID()
        _ = try await pi.send("tools:0 other", operationID: other, from: compacting)
        #expect(try await pi.send("tools:0 now", delivery: delivery, operationID: op, from: compacting) == .accepted(operationID: op))
        let waiting = try await pi.snapshot("both waiting") { $0.queue?.items.count == 2 }
        #expect(waiting.queue?.items.map(\.id) == [op, other], "first, ahead of what was queued")
        #expect(waiting.queue?.items.allSatisfy { $0.state == .queued } == true)
        #expect(prompts(pi) == ["tools:1 compact-hold"], "nothing reached pi while it compacts")
        #expect(pi.stdin("abort").isEmpty && pi.stdin("clear_queue").isEmpty)

        touch(h, "compact-done")
        let done = try await pi.snapshot("the messages to go once pi settles") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == op }
        }
        #expect(prompts(pi) == ["tools:1 compact-hold", "tools:0 now\n\ntools:0 other"], "as the next turn, the message first")
        #expect(done.queue?.paused == false)
    }

    /// pi refused the abort: nothing was stopped, so the message steers in instead, the run is not
    /// read as stopped, and the queue does not pause.
    @Test func ifPiRefusesTheAbortTheMessageSteersInInstead() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi, "tools:2 build")
        touch(h, "refuse-abort")
        let op = UUID()
        _ = try await pi.send("tools:0 now", delivery: .interrupt, operationID: op, from: running)
        let steer = try await pi.waitForStdin("prompt", count: 2)
        #expect(steer["message"] as? String == "tools:0 now" && steer["streamingBehavior"] as? String == "steer")
        pi.finishTool(1)
        let done = try await pi.snapshot("it to land and the run to settle") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == op }
        }
        #expect(done.messages.first { $0.operationID == op }?.origin == .steered)
        #expect(done.messages.first { $0.toolCallID == "call_q1" }?.status != "aborted", "nothing was stopped")
        #expect(done.queue?.paused == false)
        #expect(prompts(pi) == ["tools:2 build", "tools:0 now"])
    }

    // MARK: - Races

    /// The run ends on its own while `clear_queue` is on its way: the message goes at the settle,
    /// and no abort follows to end the turn it opens.
    @Test func ifTheRunEndsOnItsOwnFirstTheMessageGoesAndNoAbortFollows() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        touch(h, "clear-gate")
        let op = UUID()
        _ = try await pi.send("tools:0 now", delivery: .interrupt, operationID: op, from: running)
        pi.finishTool(1)
        _ = try await pi.snapshot("the message handed to pi at the settle") { s in
            !s.running && s.provisional.contains { $0.entryID == "pending:\(op.uuidString)" }
        }
        touch(h, "clear-go")
        let done = try await pi.snapshot("the message to run") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == op } && s.messages.last?.role == "assistant"
        }
        #expect(pi.stdin("abort").isEmpty, "the run had ended: there was nothing to stop")
        #expect(prompts(pi) == ["tools:1 build", "tools:0 now"], "once")
        #expect(done.messages.filter { $0.operationID == op }.count == 1)
        #expect(done.messages.last { $0.role == "assistant" }?.status != "aborted")
    }

    /// Between the stopped run and the message that follows it the agent is not done (no "Agent
    /// finished"), although the run's last reply is an error, as pi ends a run it killed: the
    /// user stopped it, and the queue goes on.
    @Test func theAgentStaysWorkingBetweenTheStoppedRunAndTheMessage() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        let status = try ExtensionClient(path: h.socketPath)
        defer { status.closeConnection() }
        func agentStatus() -> AgentStatus? { h.server.state.agents.first { $0.id == pi.agent.id }?.status }
        func reports() -> [AgentStatus] { callbacks.statuses.current.filter { $0.0 == pi.agent.id }.map(\.1) }
        let running = try await startRun(pi, "tools:2 build")
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .working))
        try await eventually("working") { agentStatus() == .working }
        // The settled run's capture is held, so the message cannot have gone yet.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            h.server.changes.captureQueue(pi.agent.id).async { continuation.resume(); release.wait() }
        }
        let op = UUID()
        _ = try await pi.send("tools:0 now", delivery: .interrupt, operationID: op, from: running)
        let stopped = try await pi.snapshot("the stopped run to settle, the message waiting") { s in
            !s.running && s.queue?.items.map(\.id) == [op] && s.messages.last { $0.role == "assistant" }?.status == "aborted"
        }
        #expect(stopped.queue?.paused == false)

        let seen = reports().count
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .done))
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .working))
        try await eventually("the reports to be read") { reports().count > seen }
        #expect(Array(reports()[seen...]) == [.working], "done was held: the message goes next")
        #expect(agentStatus() == .working)

        release.signal()
        _ = try await pi.snapshot("the message to run") { s in !s.running && s.messages.contains { $0.operationID == op } && s.messages.last?.role == "assistant" }
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .done))
        try await eventually("done once the message has been answered") { agentStatus() == .done }
    }

    /// Stop while pi is stopping for a message: Stop wins. The message stays queued, the queue waits.
    @Test func stopDuringSteerNowKeepsTheMessageQueuedAndPausesTheQueue() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        touch(h, "clear-gate")
        let op = UUID()
        _ = try await pi.send("tools:0 now", delivery: .interrupt, operationID: op, from: running)
        // pi is slow to answer the interrupt's clear_queue; Stop arrives meanwhile.
        async let stopping = pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID()))
        _ = try await pi.snapshot("Stop under way: the queue waits") { $0.queue?.paused == true }
        touch(h, "clear-go")
        #expect(try await stopping.failureCode == nil)
        let stopped = try await pi.snapshot("the stop to end the run") { s in !s.running && s.queue?.paused == true }
        #expect(stopped.queue?.items.map(\.id) == [op] && stopped.queue?.items.first?.state == .queued)
        #expect(prompts(pi) == ["tools:1 build"], "the message did not go")
    }
}

/// Through a remote client's store: a host that stops pi for a message gets an interrupt; one
/// that doesn't (no `native.interrupt.v1`) gets a steer, and the same key still sends.
@Suite("Steer now in the store", .mainActorExclusive)
@MainActor
struct InterruptStoreTests {
    @Test(arguments: [true, false])
    func aRemoteThreadInterruptsOnlyOnAHostThatCan(interrupts: Bool) async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        if !interrupts {
            remote.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.nativeInterruptCapability }
        }
        let pi = try await PiAgent.launch(on: remote.host)
        try await InterruptTests.waitForATool(pi)

        let client = try await remote.typed()
        defer { client.disconnect() }
        let store = NativeThreadStore()
        let agentID = pi.agent.id
        let task = Task { await store.run { try await client.nativeThread(agentID: agentID, request: $0) } }
        defer { task.cancel() }
        try await eventuallyOnMain("the running thread") { store.running && store.supportedActions.contains("queue") }
        #expect(store.supportedActions.contains("interrupt") == interrupts)
        #expect(store.hostInterrupts == interrupts)

        store.draft = "tools:0 now"
        await store.send(delivery: .interrupt)
        let prompts = try await InterruptTests.prompts(pi, count: 2)
        #expect(prompts.last?["message"] as? String == "tools:0 now")
        if interrupts {
            try await InterruptTests.waitForTheMessageToRun(pi, text: "tools:0 now")
            #expect(pi.stdin("abort").count == 1)
            #expect(prompts.last?["streamingBehavior"] as? String == "followUp")
        } else {
            #expect(prompts.last?["streamingBehavior"] as? String == "steer", "the older host's fallback: a plain steer")
            #expect(pi.stdin("abort").isEmpty)
        }
    }
}

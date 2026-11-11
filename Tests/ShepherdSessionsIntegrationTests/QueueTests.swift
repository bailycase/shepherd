import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The queue the host holds while pi works (`RPCThreadState+Queue`), against the stub's model of
/// pi 1.0.0's queues: a "tools:N" run makes N tool calls, each waiting for `finishTool(k)`,
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

    private func childStartReply(_ children: ExtensionClient) async throws -> ExtensionReply {
        let reply = try await children.reply()
        if case .parentInput = reply { return try await children.reply() }
        return reply
    }

    @Test(arguments: [NativeQueueMode.oneAtATime, .all])
    func normalQueueDeliversAtTheNextBoundaryAndKeepsHostEdits(mode: NativeQueueMode) async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host)
        let client = try await remote.typed()
        defer { client.disconnect() }
        let configuration = remote.host.dir.appendingPathComponent("native-queue-boundary.json")
        func boundary(expired: Bool) throws {
            var value: [String: Any] = ["agentID": pi.agent.id.rawValue, "socket": remote.host.socketPath]
            if expired { value["expiresAt"] = 1 }
            try JSONSerialization.data(withJSONObject: value).write(to: configuration, options: .atomic)
        }
        try boundary(expired: true)
        let running = try await startRun(pi, "tools:3 work")
        _ = try await pi.queue(.setMode(mode: mode), from: running)
        let edited = UUID(), deleted = UUID(), tail = UUID()
        _ = try await pi.send("outdated", operationID: edited, from: running)
        _ = try await pi.send("delete this", operationID: deleted, from: running)
        _ = try await pi.send("tail", operationID: tail, from: running)
        #expect(prompts(pi).count == 1, "the host retains the editable queue while a tool is running")

        pi.finishTool(1)
        _ = try await pi.snapshot("the next tool after an expired boundary") {
            $0.provisional.contains { $0.toolCallID == "call_q2" && $0.status == "running" }
        }
        #expect(prompts(pi).count == 1, "a late boundary cannot dispatch into the next model call")
        let replies = try String(contentsOf: remote.host.dir.appendingPathComponent("native-queue-boundary-replies.jsonl"), encoding: .utf8)
        #expect(replies.contains("stale_boundary"))

        try boundary(expired: false)
        _ = try await pi.queue(.hold(id: edited, held: true), from: running)
        pi.finishTool(2)
        _ = try await pi.snapshot("the held editor to survive a valid boundary") {
            $0.provisional.contains { $0.toolCallID == "call_q3" && $0.status == "running" }
        }
        #expect(prompts(pi).count == 1)
        func remoteEdit(_ action: NativeQueueAction) async throws -> NativeThreadResult {
            try await client.nativeThread(agentID: pi.agent.id,
                request: .queue(expectedSessionID: running.piSessionID, generation: running.generation,
                                operationID: UUID(), action: action))
        }
        #expect(try await remoteEdit(.edit(id: edited, text: "tools:1 edited")).failureCode == nil)
        #expect(try await remoteEdit(.delete(id: deleted)).failureCode == nil)
        pi.finishTool(3)
        let delivered = try await pi.snapshot("the edited queue message before another model step") {
            $0.provisional.contains { $0.toolCallID == "call_q4" && $0.status == "running" }
        }
        let second = try await pi.waitForStdin("prompt", count: 2)
        #expect(second["streamingBehavior"] as? String == "steer")
        #expect(second["message"] as? String == (mode == .all ? "tools:1 edited\n\ntail" : "tools:1 edited"))
        #expect(delivered.queue?.items.count == (mode == .all ? 0 : 1))
        #expect(pi.stdin("abort").isEmpty, "automatic boundary delivery never cancels the tool batch")
        pi.finishTool(4)
        let done = try await pi.snapshot("the queue to settle and its history to load, once, in order") { s in
            !s.running && s.queue?.items.isEmpty == true
                && s.messages.contains { $0.operationID == edited }
                && (mode == .all || s.messages.contains { $0.operationID == tail })
        }
        #expect(prompts(pi).count == (mode == .all ? 2 : 3))
        let users = done.messages.filter { $0.role == "user" }.map { $0.blocks.map(\.text).joined() }
        #expect(users.filter { $0.contains("edited") }.count == 1)
        #expect(!users.contains("outdated") && !users.contains("delete this"))
        let message = try #require(done.messages.first { $0.role == "user" && $0.blocks.contains { $0.text.contains("edited") } })
        let parts = try #require(message.origin?.parts)
        #expect(parts.map { $0.id } == (mode == .all ? [edited, tail] : [edited]))
    }

    @Test(arguments: [true, false])
    func stopAndStrandedRunsReclaimBoundaryBatchesWithTheirOriginalIDsAndImageBytes(hostStop: Bool) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        var config: [String: Any] = ["agentID": pi.agent.id.rawValue, "socket": host.socketPath]
        if hostStop { config["gate"] = "boundary-release" } else { config["abortAfterAck"] = true }
        try JSONSerialization.data(withJSONObject: config).write(to: host.dir.appendingPathComponent("native-queue-boundary.json"))
        let running = try await startRun(pi)
        _ = try await pi.queue(.setMode(mode: .all), from: running)
        let first = UUID(), second = UUID()
        let image = NativeImage(mimeType: "image/png", data: Data([1, 2, 3]), name: "kept.png")
        _ = try await pi.send("tools:0 image queue", images: [image], operationID: first, from: running)
        _ = try await pi.send("tail", operationID: second, from: running)
        pi.finishTool(1)
        _ = try await pi.waitForStdin("prompt", count: 2)
        try await eventually("pi to await release after the host acknowledged the boundary") {
            FileManager.default.fileExists(atPath: host.dir.appendingPathComponent("native-queue-boundary-replies.jsonl").path)
        }
        if hostStop {
            #expect(try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID())).failureCode == nil)
            let stopped = try await pi.snapshot("the original queue records to return on Stop") {
                !$0.running && $0.queue?.paused == true && $0.queue?.items.count == 2
            }
            #expect(stopped.queue?.items.map { $0.id } == [first, second])
            #expect(stopped.queue?.items.first?.images.count == 1)
            _ = try await pi.queue(.sendNow(ids: [first, second]), from: stopped)
        }
        let sent = try await pi.waitForStdin("prompt", count: 3)
        let images = try #require(sent["images"] as? [[String: Any]])
        #expect(images.first?["data"] as? String == image.data.base64EncodedString())
        let done = try await pi.snapshot { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == first }
        }
        let delivered = done.messages.filter { $0.role == "user" && $0.blocks.contains { $0.text.contains("image queue") } }
        #expect(delivered.count == 1)
        #expect(delivered.first?.origin?.parts?.map { $0.id } == [first, second])
    }

    @Test func equalTextKeepsBoundaryAndExplicitSteerOwnershipInOrder() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        let config: [String: Any] = ["agentID": pi.agent.id.rawValue, "socket": host.socketPath, "gate": "boundary-release"]
        try JSONSerialization.data(withJSONObject: config).write(to: host.dir.appendingPathComponent("native-queue-boundary.json"))
        let running = try await startRun(pi)
        let automatic = UUID(), explicit = UUID(), text = "tools:0 same"
        let image = NativeImage(mimeType: "image/png", data: Data([7, 8, 9]), name: "automatic.png")
        _ = try await pi.send(text, images: [image], operationID: automatic, from: running)
        pi.finishTool(1)
        _ = try await pi.waitForStdin("prompt", count: 2)
        _ = try await pi.send(text, delivery: .steer, operationID: explicit, from: running)
        _ = try await pi.waitForStdin("prompt", count: 3)
        #expect(try await pi.queue(.unsteer(id: explicit), from: running).failureCode == nil)
        let restored = try await pi.waitForStdin("prompt", count: 4)
        let images = try #require(restored["images"] as? [[String: Any]])
        #expect(images.first?["data"] as? String == image.data.base64EncodedString())
        #expect(try await pi.queue(.steer(ids: [explicit]), from: running).failureCode == nil)
        _ = try await pi.waitForStdin("prompt", count: 5)
        try Data().write(to: host.dir.appendingPathComponent("boundary-release"))
        let done = try await pi.snapshot { s in
            !s.running && s.queue?.items.isEmpty == true
                && s.messages.contains { $0.operationID == automatic }
                && s.messages.contains { $0.operationID == explicit }
        }
        let messages = done.messages.filter { $0.role == "user" && $0.blocks.filter { $0.kind == .text }.map(\.text).joined() == text }
        #expect(messages.compactMap { $0.operationID } == [automatic, explicit])
        #expect(messages.first?.origin?.parts?.map { $0.id } == [automatic])
        #expect(messages.last?.origin == .steered)
        #expect(pi.stdin("abort").isEmpty)
    }

    @Test(arguments: [true, false], [false, true])
    func unsteeringEqualTextKeepsEachRecordsImagesAndOperationID(returnFirst: Bool, failRestore: Bool) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        let running = try await startRun(pi)
        let first = UUID(), second = UUID(), text = "tools:0 identical"
        let firstImage = NativeImage(mimeType: "image/png", data: Data([1, 2, 3]), name: "first.png")
        let secondImage = NativeImage(mimeType: "image/png", data: Data([7, 8, 9]), name: "second.png")
        #expect(try await pi.send(text, delivery: .steer, images: [firstImage], operationID: first, from: running).failureCode == nil)
        #expect(try await pi.send(text, delivery: .steer, images: [secondImage], operationID: second, from: running).failureCode == nil)
        let returned = returnFirst ? first : second, kept = returnFirst ? second : first
        let returnedImage = returnFirst ? firstImage : secondImage, keptImage = returnFirst ? secondImage : firstImage
        try await host.server.enqueue {
            let thread = try #require(host.server.rpcThread(forAgent: pi.agent.id))
            thread.paused = true // The explicitly returned record must wait for an explicit send.
            if failRestore { thread.onPrepareRecovery = { _, _, _, completion in completion(false) } }
        }
        let result = try await pi.queue(.unsteer(id: returned), from: running)
        #expect(result.failureCode == (failRestore ? "persist_failed" : nil))
        try await host.server.enqueue {
            let thread = try #require(host.server.rpcThread(forAgent: pi.agent.id))
            #expect(thread.items.count == 2 && Set(thread.items.map(\.entry.id)) == Set([first, second]))
            #expect(thread.items.first { $0.entry.id == first }?.images == [firstImage])
            #expect(thread.items.first { $0.entry.id == second }?.images == [secondImage])
            #expect(thread.items.first { $0.entry.id == returned }?.entry.state == .queued)
            #expect(thread.items.first { $0.entry.id == kept }?.entry.state == (failRestore ? .queued : .steering))
            #expect(thread.steersInFlight == 0)
        }
        if failRestore {
            #expect(pi.stdin("prompt").count == 3, "failed restoration must retain both records without replay")
            return
        }
        let restored = try await pi.waitForStdin("prompt", count: 4)
        let restoredImages = try #require(restored["images"] as? [[String: Any]])
        #expect(restoredImages.first?["data"] as? String == keptImage.data.base64EncodedString())
        pi.finishTool(1)
        let consumed = try await pi.snapshot("only the remaining equal-text steer to be consumed") {
            !$0.running && $0.messages.contains { $0.operationID == kept }
        }
        #expect(consumed.messages.filter { $0.operationID == kept }.count == 1)
        #expect(!consumed.messages.contains { $0.operationID == returned })
        #expect(consumed.queue?.items.map(\.id) == [returned])
        #expect(try await pi.queue(.sendNow(ids: [returned]), from: consumed).failureCode == nil)
        let sent = try await pi.waitForStdin("prompt", count: 5)
        let sentImages = try #require(sent["images"] as? [[String: Any]])
        #expect(sentImages.first?["data"] as? String == returnedImage.data.base64EncodedString())
        let done = try await pi.snapshot("both original operations consumed once") {
            !$0.running && $0.queue?.items.isEmpty == true && $0.messages.contains { $0.operationID == returned }
        }
        #expect(done.messages.filter { $0.operationID == first || $0.operationID == second }.compactMap(\.operationID) == [kept, returned])
        #expect(pi.stdin("prompt").count == 5)
    }

    @Test func queuedSubagentStartsWithoutInterruptingTheParentAndKeepsImages() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let children = try ExtensionClient(path: h.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        // The projection fences registration of the controller before the request.
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "ready", label: "Ready", state: "complete")]))
        _ = try await pi.snapshot { $0.subagents?.count == 1 }
        let queuedID = UUID(), operation = UUID()
        let image = NativeImage(mimeType: "image/png", data: Data(repeating: 1, count: 900_000), name: "screen.png")
        let element = BrowserElement(page: "http://localhost:5173", selector: "button.pay", label: "Pay", width: 100, height: 40, html: "<button>Pay</button>")
        _ = try await pi.request(.send(expectedSessionID: running.piSessionID, generation: running.generation,
                                      operationID: queuedID, text: "Review this screen", delivery: .followUp, images: [image], browserElements: [element]))
        let request = NativeThreadRequest.queue(expectedSessionID: running.piSessionID, generation: running.generation,
                                                operationID: operation, action: .subagent(id: queuedID))
        do {
            async let result = pi.request(request)
            guard case .childStart(let id, let requestID, let text, let images) = try await childStartReply(children) else {
                Issue.record("expected childStart"); return
            }
            let context = try #require(BrowserElementFence.parse(text))
            #expect(requestID == queuedID.uuidString && context.text == "Review this screen" && images == [image])
            #expect(context.elements == [element.clamped])
            let pending = try await pi.snapshot { $0.queue?.items.count == 1 }
            #expect(pending.running && prompts(pi) == ["tools:1 build"] && pi.stdin("abort").isEmpty)
            #expect(try await pi.queue(.delete(id: queuedID), from: running).failureCode == "queue_busy")
            try children.send(.childCommandResult(id: id, error: nil))
            #expect(try await result == .accepted(operationID: operation))
        }
        #expect(try await pi.request(request) == .accepted(operationID: operation))
        let launched = try await pi.snapshot { $0.queue?.items.isEmpty == true }
        #expect(launched.running && prompts(pi) == ["tools:1 build"] && pi.stdin("abort").isEmpty)
        #expect(try await pi.queue(.subagent(id: queuedID), from: running).failureCode == "queue_item_unavailable")
    }

    @Test func failedSubagentStartupRetainsTheQueuedMessageAndDoesNotDrainDuringAdmission() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let children = try ExtensionClient(path: h.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "ready", label: "Ready", state: "complete")]))
        _ = try await pi.snapshot { $0.subagents?.count == 1 }
        let queuedID = UUID()
        _ = try await pi.send("tools:0 review", operationID: queuedID, from: running)
        do {
            async let result = pi.queue(.subagent(id: queuedID), from: running)
            guard case .childStart(let id, _, _, _) = try await childStartReply(children) else { Issue.record("expected childStart"); return }
            pi.finishTool(1)
            _ = try await pi.snapshot { !$0.running }
            #expect(prompts(pi) == ["tools:1 build"])
            try children.send(.childCommandResult(id: id, error: "Four children are already active"))
            #expect(try await result.failureCode == "child_start_failed")
        }
        let kept = try await pi.snapshot { $0.queue?.paused == true }
        #expect(kept.queue?.items.map(\.id) == [queuedID])
        #expect(prompts(pi) == ["tools:1 build"])
        #expect(try await pi.queue(.sendNow(ids: [queuedID]), from: kept).failureCode == nil)
        _ = try await pi.snapshot { $0.messages.contains { $0.operationID == queuedID } }
    }

    @Test func aLostStartupAcknowledgementKeepsTheMessageOutOfTheParentUntilReconciled() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let children = try ExtensionClient(path: h.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "ready", label: "Ready", state: "complete")]))
        _ = try await pi.snapshot { $0.subagents?.count == 1 }
        let queuedID = UUID()
        _ = try await pi.send("tools:0 delegated", operationID: queuedID, from: running)
        do {
            async let result = pi.queue(.subagent(id: queuedID), from: running)
            guard case .childStart = try await childStartReply(children) else { Issue.record("expected childStart"); return }
            children.closeConnection()
            #expect(try await result.failureCode == "child_start_failed")
        }
        #expect(try await pi.queue(.sendNow(ids: [queuedID]), from: running).failureCode == "outcome_unknown")
        // Delete/Undo cannot accidentally turn an uncertain launch into another parent prompt.
        #expect(try await pi.queue(.delete(id: queuedID), from: running).failureCode == nil)
        #expect(try await pi.queue(.restore(ids: [queuedID], index: 0), from: running).failureCode == nil)
        _ = try await pi.send("tools:0 new message", from: running)
        pi.finishTool(1)
        _ = try await pi.snapshot { !$0.running }
        #expect(prompts(pi) == ["tools:1 build"])
        let reconnected = try ExtensionClient(path: h.socketPath)
        try reconnected.send(.helloChildren(agentID: pi.agent.id))
        try reconnected.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "reconnected", label: "Ready", state: "complete")]))
        _ = try await pi.snapshot { $0.subagents?.first?.runID == "reconnected" }
        do {
            async let result = pi.queue(.subagent(id: queuedID), from: running)
            guard case .childStart(let id, let requestID, _, _) = try await reconnected.reply() else { Issue.record("expected retry"); return }
            #expect(requestID == queuedID.uuidString, "the extension reconciles the same launch")
            try reconnected.send(.childCommandResult(id: id, error: nil))
            #expect(try await result.failureCode == nil)
        }
        #expect(!prompts(pi).contains("tools:0 delegated"))
    }

    @Test func queuedSubagentRejectsHeldSteeringAndStaleMessages() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let id = UUID()
        _ = try await pi.send("tools:0 queued", operationID: id, from: running)
        #expect(try await pi.queue(.hold(id: id, held: true), from: running).failureCode == nil)
        #expect(try await pi.queue(.subagent(id: id), from: running).failureCode == "queue_item_unavailable")
        _ = try await pi.queue(.hold(id: id, held: false), from: running)
        #expect(try await pi.queue(.subagent(id: id), from: running).failureCode == "child_start_failed", "no controller connected")
        _ = try await pi.queue(.steer(ids: [id]), from: running)
        #expect(try await pi.queue(.subagent(id: id), from: running).failureCode == "queue_item_unavailable")
        #expect(try await pi.request(.queue(expectedSessionID: running.piSessionID, generation: "stale", operationID: UUID(),
                                           action: .subagent(id: id))).failureCode == "stale_session")
    }

    // MARK: - Delivery

    /// An element picked in the Browser rides the queue: the queue shows it without its markup,
    /// the message goes to pi on its own with the element fenced ahead of its words, and the
    /// thread shows the words with the element as a chip.
    @Test func aQueuedMessageKeepsItsBrowserElementsAndGoesAloneWithTheirFence() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let element = BrowserElement(page: "http://localhost:5173/checkout", selector: "main > button.pay", label: "button.pay",
                                     source: "src/Checkout.tsx:88", width: 240, height: 44, html: "<button class=\"pay\">Pay</button>")
        let plain = UUID(), picked = UUID()
        _ = try await pi.send("tools:0 first", operationID: plain, from: running)
        #expect(try await pi.request(.send(expectedSessionID: running.piSessionID, generation: running.generation, operationID: picked,
                                           text: "tools:0 wider", delivery: .followUp, browserElements: [element])) == .accepted(operationID: picked))
        let queued = try await pi.snapshot("both in the queue") { $0.queue?.items.count == 2 }
        #expect(queued.queue?.items.last?.elements == [element.withoutHTML])
        #expect(queued.queue?.items.last?.text == "tools:0 wider")

        pi.finishTool(1)
        let done = try await pi.snapshot("both delivered and settled") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == picked }
                && s.messages.last?.role == "assistant"
        }
        let sent = prompts(pi)
        #expect(sent.contains("tools:0 first"), "the plain message went on its own")
        let fenced = try #require(sent.last)
        let parsed = try #require(BrowserElementFence.parse(fenced))
        #expect(parsed.elements == [element.clamped] && parsed.text == "tools:0 wider", "the element with its markup, then the words")
        let delivered = try #require(done.messages.first { $0.operationID == picked })
        #expect(delivered.browserElements == [element.withoutHTML])
        #expect(delivered.blocks.map(\.text) == ["tools:0 wider"])
    }

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

    /// Clients that connected while the server queue was busy waited in the listener's backlog
    /// and were accepted once it freed: each still keeps what its own hello said, so an older
    /// one's queued messages go alone while a current one's go together.
    @Test func clientsAcceptedFromTheBacklogKeepTheQueueTheirHelloAskedFor() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host)
        let running = try await startRun(pi)
        let release = DispatchSemaphore(value: 0)
        await remote.server.holdQueue(until: release)
        // The kernel completes these handshakes in the backlog; the held queue accepts neither yet.
        let clients: [RawRemote]
        do {
            defer { release.signal() }
            clients = try (0..<4).map { _ in try RawRemote(port: remote.port) }
        }
        for (index, client) in clients.enumerated() {
            try await client.hello(token: remote.token, capabilities: index % 2 == 0 ? nil : RemoteProtocol.clientCapabilities)
        }
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
        try await send("tools:0 old one", from: clients[0])
        try await send("tools:0 old two", from: clients[2])
        try await send("tools:0 new one", from: clients[1])
        try await send("tools:0 new two", from: clients[3])
        _ = try await pi.snapshot { $0.queue?.items.count == 4 }

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

    @Test func takingBackASteerPreservesIdenticalMessagesWithDifferentImages() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let back = UUID(), first = UUID(), second = UUID()
        _ = try await pi.send("tools:0 wait", delivery: .steer, operationID: back, from: running)
        for (id, byte) in [(first, UInt8(1)), (second, UInt8(2))] {
            let image = NativeImage(mimeType: "image/png", data: Data([byte]), name: "image.png")
            _ = try await pi.send("tools:0 look", delivery: .steer, images: [image], operationID: id, from: running)
        }
        #expect(try await pi.queue(.unsteer(id: back), from: running).failureCode == nil)
        _ = try await pi.waitForStdin("prompt", count: 6)
        let restored = pi.stdin("prompt").suffix(2).compactMap { ($0["images"] as? [[String: Any]])?.first?["data"] as? String }
        #expect(restored == [Data([1]).base64EncodedString(), Data([2]).base64EncodedString()])
        pi.finishTool(1)
        let done = try await pi.snapshot("both identical steers to land and the queue to drain") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == back }
        }
        #expect(done.messages.first { $0.operationID == first }?.origin == .steered)
        #expect(done.messages.first { $0.operationID == second }?.origin == .steered)
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
        let releaseCapture = DispatchSemaphore(value: 0)
        defer { releaseCapture.signal() }
        await withCheckedContinuation { continuation in
            h.server.changes.captureQueue(pi.agent.id).async { continuation.resume(); releaseCapture.wait() }
        }

        #expect(try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID())).failureCode == nil)
        let types = pi.stdin().compactMap { $0["type"] as? String }
        let clear = try #require(types.firstIndex(of: "clear_queue"))
        let abort = try #require(types.firstIndex(of: "abort"))
        #expect(clear < abort)
        // pi ends a run stopped mid-tool-call with an error reply (the stub does too), which the
        // host projects as the stop it was.
        let stopped = try await pi.snapshot("the run to end in its reply to the stop") { s in
            !s.running && s.messages.last { $0.role == "assistant" }?.status == "aborted"
        }
        #expect(stopped.queue?.items.map(\.id) == [steer, follow] && stopped.queue?.items.allSatisfy { $0.state == .queued } == true)
        #expect(stopped.queue?.paused == true)
        #expect(stopped.queue?.notice == nil, "the queue waits because of the stop, not a turn that failed")
        #expect(!stopped.messages.contains { $0.operationID == steer }, "the steer did not land in the stopped run")
        #expect(prompts(pi).count == 2, "a stopped queue waits")

        // Send now resumes it: that message opens the next turn, and the rest follows.
        #expect(try await pi.queue(.sendNow(ids: [follow]), from: stopped).failureCode == nil)
        #expect(prompts(pi).count == 2, "Send now resumes intent but cannot bypass the held capture")
        releaseCapture.signal()
        _ = try await pi.snapshot("both to go") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.operationID == steer }
        }
        #expect(prompts(pi).suffix(2) == ["tools:0 after", "tools:0 instead"])
    }

    @Test func deletingTheDeferredSendNowSelectionStillDrainsTheRemainingQueue() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let first = UUID(), second = UUID()
        _ = try await pi.send("tools:0 first", operationID: first, from: running)
        _ = try await pi.send("tools:0 second", operationID: second, from: running)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            h.server.changes.captureQueue(pi.agent.id).async { continuation.resume(); release.wait() }
        }
        pi.finishTool(1)
        let settled = try await pi.snapshot("settled with capture held") { !$0.running }
        #expect(try await pi.queue(.sendNow(ids: [first]), from: settled).failureCode == nil)
        #expect(try await pi.queue(.delete(id: first), from: settled).failureCode == nil)
        release.signal()
        _ = try await pi.waitForStdin("prompt", count: 2)
        #expect(prompts(pi).last == "tools:0 second")
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
        let text = "please refuse"
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let op = UUID()
        _ = try await pi.send(text, operationID: op, from: running)
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

    @Test func queueEditsAndUndoPreserveAdmissionLimitsAndRejectedContent() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { _ = try await pi.send("small", operationID: id, from: running) }
        let plain = String(repeating: "x", count: 64 * 1024)
        for id in ids.prefix(3) {
            #expect(try await pi.queue(.edit(id: id, text: plain), from: running).failureCode == nil)
        }
        let edited = try await pi.snapshot { $0.queue?.items.count == 5 }
        #expect(edited.queue?.items.map(\.text) == [plain, plain, plain, "small", "small"])

        _ = try await pi.queue(.clear, from: running)
        let refill = (0..<32).map { _ in UUID() }
        for id in refill { _ = try await pi.send("refill", operationID: id, from: running) }
        #expect(try await pi.queue(.restore(ids: ids, index: 0), from: running).failureCode == "queue_full")
        let full = try await pi.snapshot { $0.queue?.items.count == 32 }
        #expect(full.queue?.items.map(\.id) == refill)
        // Refusal must retain the undo record: freeing room lets the same restore succeed.
        _ = try await pi.queue(.clear, from: running)
        #expect(try await pi.queue(.restore(ids: ids + ids, index: 0), from: running).failureCode == nil)
        let restored = try await pi.snapshot { $0.queue?.items.count == 5 }
        #expect(restored.queue?.items.map(\.id) == ids)
        #expect(restored.queue?.items.map(\.text) == [plain, plain, plain, "small", "small"])
    }

    @Test func escapeHeavyQueueTextIsNotLimitedByTheOldSnapshotBudget() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let id = UUID()
        _ = try await pi.send("keep me", operationID: id, from: running)
        let escaped = String(repeating: "\u{0001}", count: 20 * 1024)
        #expect(try await pi.send(escaped, from: running).failureCode == nil)
        #expect(try await pi.queue(.edit(id: id, text: escaped), from: running).failureCode == nil)
        #expect(try await pi.send(escaped, from: running).failureCode == nil)
        let snapshot = try await pi.snapshot { $0.queue?.items.count == 3 }
        #expect(snapshot.queue?.items.map(\.text) == [escaped, escaped, escaped])
        #expect(try JSONEncoder().encode(RemoteReply.nativeThread(id: 1, result: .snapshot(value: snapshot))).count < NDJSON.maxPayloadBytes)
    }

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

    /// pi exiting mid-run (a crash the steer caused, here) keeps its agent and its queue: the file holds
    /// the queue paused and inactive, nothing is admitted at the next start, and the thread says it
    /// stopped. A request that failed with the exit stages no write over it.
    @Test func piExitingWithAQueueHoldsTheQueueForRetry() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        let s = try await startRun(pi)
        _ = try await pi.send("tools:0 queued", from: s)
        _ = try? await pi.send("die", delivery: .steer, from: s)
        try await eventually("the exit") { callbacks.exited(pi.sessionID) }
        let exit = try #require(callbacks.sessionExits.current[pi.sessionID])
        #expect(exit.keepsAgent && exit.code == 3)
        #expect(exit.startProblem == NativeStartProblem(kind: .stopped, exitCode: 3, lines: ["stub-pi: dying"]))

        try await eventually("no recovery write in flight") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let saved = try #require(try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id))
        #expect(saved.items.map(\.entry.text) == ["tools:0 queued"])
        #expect(!saved.active && saved.paused && saved.heldAfterExit == true)
        #expect(await h.server.agentsNeedingStartupRecovery().isEmpty)

        let error = await #expect(throws: RemoteHostClientError.self) {
            _ = try await pi.send("anything", from: s)
        }
        guard case .rejected("native_unavailable", let message)? = error else { Issue.record("expected native_unavailable, got \(String(describing: error))"); return }
        #expect(message == "The agent stopped. Retry to start it again.")
        let snapshot = try await pi.request(.snapshot()).snapshotValue
        #expect(snapshot?.startProblem?.kind == .stopped)
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

    /// The status extension's socket can run a whole run ahead of pi's stdout while a long record
    /// decodes: B's done arrives while B's prompt is still unanswered and is held, and B's
    /// `agent_start` is read after it. The held done outlives that start, stays held while B runs,
    /// and lands when B settles.
    @Test func aDoneThatOvertakesItsRunsStartLandsWhenTheRunSettles() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let armed = Locked(false)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.server.beforeOffQueueDecode = {
            guard armed.withValue({ armed in defer { armed = false }; return armed }) else { return }
            entered.signal()
            release.wait()
        }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_HISTORY_BYTES": String(1024 * 1024)])
        let ready = try await pi.ready()
        let status = try ExtensionClient(path: h.socketPath)
        defer { status.closeConnection() }
        func agentStatus() -> AgentStatus? { h.server.state.agents.first { $0.id == pi.agent.id }?.status }
        func doneHeld() async throws -> Bool { try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.doneHeld == true } }

        _ = try await pi.send("tools:0 first", from: ready)
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .working))
        _ = try await pi.snapshot("the first run to settle") { s in
            !s.running && s.messages.contains { $0.blocks.first?.text == "Reply to tools:0 first" }
        }
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .done))
        try await eventually("done after the first run") { agentStatus() == .done }

        armed.withValue { $0 = true }
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)!.refreshMessages() }
        #expect(try await blocking { entered.wait(timeout: .now() + 30) == .success }, "a long history reached the decoder")

        let second = UUID()
        let b = Task { try await pi.send("tools:0 second hold-settle", operationID: second, from: ready) }
        _ = try await pi.waitForStdin("prompt", count: 2)
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .working))
        try status.send(.setAgentStatus(agentID: pi.agent.id, status: .done))
        try await eventually("the done to be held") { try await doneHeld() }
        #expect(agentStatus() == .working, "the second run's prompt is unanswered: the agent is not done")

        release.signal()
        #expect(try await b.value == .accepted(operationID: second))
        _ = try await pi.snapshot("the second run, after its start, before it settles") { s in
            s.running && s.provisional.contains { $0.role == "assistant" && $0.status == "stop" }
        }
        #expect(agentStatus() == .working, "the second run is going: the held done is not applied")
        #expect(try await doneHeld())

        pi.releaseSettle()
        _ = try await pi.snapshot("the second run to settle") { s in
            !s.running && s.messages.contains { $0.blocks.first?.text == "Reply to tools:0 second hold-settle" }
        }
        try await eventually("done once the second run settles") { agentStatus() == .done }
        #expect(try await !doneHeld())
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

    // MARK: - The data path

    /// A queue change is a new revision like any of pi's, so a thread on screen hears of it
    /// from the server's push, not only from its next poll. The run waits on its tool call
    /// throughout: nothing but the queue moves.
    @Test func eachQueueChangeReachesAWatchedThreadThroughAPush() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pushes = Locked<[AgentID]>([])
        h.server.onThreadRevision = { agentID in pushes.withValue { $0.append(agentID) } }
        let pi = try await PiAgent.launch(on: h)
        let running = try await startRun(pi)
        let first = UUID(), second = UUID()
        _ = try await pi.send("tools:0 first", operationID: first, from: running)
        _ = try await pi.send("tools:0 second", operationID: second, from: running)
        _ = try await pi.snapshot { $0.queue?.items.count == 2 }
        h.server.watchThreadRevisions(of: [pi.agent.id])
        await drainMainQueue()

        func pushed(_ what: String, by change: () async throws -> Void) async throws {
            let seen = pushes.current.count
            try await change()
            try await eventually("\(what) to be pushed") { pushes.current.count > seen }
            #expect(pushes.current.dropFirst(seen).allSatisfy { $0 == pi.agent.id })
        }
        try await pushed("the host's default mode") { h.server.setDefaultQueueMode(.oneAtATime) }
        try await pushed("a send") { _ = try await pi.send("tools:0 third", from: running) }
        let actions: [(String, NativeQueueAction)] = [
            ("an edit", .edit(id: first, text: "tools:0 first, edited")), ("a move", .move(id: second, index: 0)),
            ("a hold", .hold(id: first, held: true)), ("a release", .hold(id: first, held: false)),
            ("a mode", .setMode(mode: .all)), ("a delete", .delete(id: second)),
        ]
        for (what, action) in actions {
            try await pushed(what) {
                let result = try await pi.queue(action, from: running)
                #expect(result.failureCode == nil, "\(what): \(result)")
            }
        }
        let queued = try await pi.snapshot()
        #expect(queued.queue?.items.map(\.text) == ["tools:0 first, edited", "tools:0 third"])
        #expect(queued.queue?.mode == .all)
    }

    /// A long history decodes off the server queue, and everything pi wrote after it waits in
    /// line: the queue goes when pi settles, but the user message pi starts with it is handled
    /// only after the history, and still finds the delivery it belongs to.
    @Test func aDeliveryPiStartsBehindALongHistoryWaitsForItAndKeepsItsOrigin() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let armed = Locked(false)
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.server.beforeOffQueueDecode = {
            guard armed.withValue({ armed in defer { armed = false }; return armed }) else { return }
            holding.signal()
            release.wait()
        }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_HISTORY_BYTES": String(1024 * 1024)])
        let running = try await startRun(pi)
        let op = UUID()
        _ = try await pi.send("tools:0 next", operationID: op, from: running)
        _ = try await pi.snapshot { $0.queue?.items.count == 1 }
        // A run's end no longer reads the history (its messages fold), so the read is asked for as the run settles: after the
        // run's last event and before the queue sends pi its next prompt, where the run's own read used to come.
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            let previous = thread.onActualTurnSettled
            thread.onActualTurnSettled = { [weak thread] in previous?(); thread?.refreshMessages() }
        }

        armed.withValue { $0 = true }
        pi.finishTool(1)
        #expect(try await blocking { holding.wait(timeout: .now() + 30) == .success }, "the run's history reached the decoder")
        _ = try await pi.waitForStdin("prompt", count: 2)
        let waiting = try await pi.snapshot()
        #expect(waiting.queue?.items.isEmpty == true, "the queue went when pi settled")
        #expect(waiting.provisional.contains { $0.entryID == "pending:\(op.uuidString)" })
        #expect(!waiting.provisional.contains { $0.role == "user" && $0.operationID == op && !$0.entryID.hasPrefix("pending:") },
                "pi's user message waits behind the history")

        release.signal()
        let done = try await pi.snapshot("the delivery to settle", timeout: .seconds(30)) { s in
            !s.running && s.messages.last?.role == "assistant" && s.messages.contains { $0.operationID == op }
        }
        let delivered = try #require(done.messages.firstIndex { $0.operationID == op })
        #expect(done.messages[delivered].origin?.parts?.map(\.id) == [op])
        let firstReply = try #require(done.messages.firstIndex { $0.blocks.first?.text == "Reply to tools:1 build" })
        #expect(firstReply < delivered, "the delivery follows the run it waited for")
        #expect(done.provisional.isEmpty)
    }
}

/// The reported bug, end to end: a message whose run adds more than a page of history must
/// not stay drawn at the tail after later replies. The host now shows pi's user message where
/// pi read it, and the store drops its echo at the host's next snapshot instead of waiting to
/// find the text on the newest page. The prompt stays in the thread where pi read it, above the
/// reply: the store joins the pages between when the newest page starts inside the turn.
@Suite("Queue and steer in the store", .mainActorExclusive)
@MainActor
struct QueueStoreTests {
    private nonisolated func remoteSnapshot(_ pi: PiAgent, children: Bool = false) async throws {
        _ = try await pi.snapshot { children ? $0.subagents?.count == 1 : $0.running }
    }

    @Test(arguments: [true, false])
    func remoteQueuedSubagentsAreCapabilityGatedAndWaitForHostAcceptance(supported: Bool) async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        if !supported {
            remote.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.nativeQueueSubagentCapability }
        }
        let pi = try await PiAgent.launch(on: remote.host)
        let ready = try await pi.ready()
        _ = try await pi.send("tools:1 build", from: ready)
        try await remoteSnapshot(pi)
        let client = try await remote.typed()
        defer { client.disconnect() }
        let store = NativeThreadStore()
        let task = Task { await store.run { try await client.nativeThread(agentID: pi.agent.id, request: $0) } }
        defer { task.cancel() }
        try await eventuallyOnMain("the running remote thread") { store.ready && store.running }
        #expect(store.supportsQueueSubagent == supported)
        store.draft = "tools:0 review"
        await store.send()
        let queued = try #require(store.queue.first?.id)
        guard supported else {
            await store.runQueuedInSubagent(queued)
            #expect(store.queue.count == 1)
            return
        }
        let children = try ExtensionClient(path: remote.host.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "ready", label: "Ready", state: "complete")]))
        try await remoteSnapshot(pi, children: true)
        let launch = Task { await store.runQueuedInSubagent(queued) }
        guard case .childStart(let id, let requestID, _, _) = try await children.reply() else { Issue.record("expected remote childStart"); return }
        #expect(requestID == queued.uuidString && store.queue.map(\.id) == [queued])
        try children.send(.childCommandResult(id: id, error: nil))
        await launch.value
        #expect(store.queue.isEmpty && store.running)
        #expect(pi.stdin("prompt").count == 1 && pi.stdin("abort").isEmpty)
    }

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
        // Its saved reply, not a reply left from before the send.
        try await eventuallyOnMain("the run to settle") {
            store.snapshot?.running == false
                && store.messages.last.map { $0.role == "assistant" && $0.blocks.contains { $0.text.hasPrefix("Reply to tools:30") } } == true
        }
        #expect(store.pending.isEmpty)
        #expect(store.displayedMessages.last?.role == "assistant")
        let shown = store.displayedMessages
        let prompts = shown.indices.filter { shown[$0].role == "user" && shown[$0].blocks.first?.text == "tools:30 ye" }
        #expect(prompts.count == 1, "the prompt is drawn once")
        #expect(prompts.first.map { prompt in shown[(prompt + 1)...].contains { $0.toolName != nil || $0.role == "toolResult" } } == true,
                "the prompt opens its turn, above its calls and reply, never drawn at the tail")
    }
}

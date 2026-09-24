import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// `SessionServer.nativeThread` for an RPC agent: the thread the app renders and the actions it
/// sends, served from the agent's own pi process (the stub).
@Suite("Native thread over RPC", .integrationTimeLimit)
struct NativeThreadTests {
    private let stale = NativeThreadResult.failure(code: "stale_session", message: "Refresh the thread before acting.")

    // MARK: - Sending

    /// An idle agent gets a plain prompt; while it streams, a send carries the delivery mode.
    @Test func sendsPromptWhenIdleAndQueueWithTheirDeliveryWhileRunning() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()

        #expect(try await pi.send("slow", delivery: .steer, from: idle).failureCode == nil)
        let first = try await pi.waitForStdin("prompt")
        #expect(first["message"] as? String == "slow")
        #expect(first["streamingBehavior"] == nil, "an idle agent is prompted, never steered")

        let streaming = try await pi.snapshot("the paused turn to stream") { $0.running && !$0.provisional.isEmpty }
        #expect(try await pi.send("follow this up", delivery: .followUp, from: streaming).failureCode == nil)
        #expect(try await pi.waitForStdin("prompt", count: 2)["streamingBehavior"] as? String == "followUp")
        #expect(try await pi.send("steer now", delivery: .steer, from: streaming).failureCode == nil)
        #expect(try await pi.waitForStdin("prompt", count: 3)["streamingBehavior"] as? String == "steer")
        pi.release(1)
        pi.release(2)
    }

    /// While a turn streams the thread shows it provisionally; the settled history replaces it.
    @Test func aTurnStreamsProvisionallyThenSettlesIntoHistory() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        _ = try await pi.send("slow", from: idle)

        let partial = try await pi.snapshot("the first deltas") { $0.provisional.first?.blocks.first?.text == "Hello line\u{2028}sep" }
        #expect(partial.running)
        #expect(partial.provisional.first?.status == "streaming")
        #expect(partial.revision > idle.revision)

        pi.release(1)
        let tooling = try await pi.snapshot("the running tool") { $0.provisional.contains { $0.toolCallID == "call_abc123" } }
        #expect(tooling.provisional.first?.status == "toolUse")
        let tool = try #require(tooling.provisional.first { $0.toolCallID == "call_abc123" })
        #expect(tool.status == "running" && tool.argumentsText == #"{"command":"ls"}"#)
        let toolStarted = try #require(tool.startedAt)

        pi.release(2)
        let done = try await pi.snapshot("the settled history") { !$0.running && $0.provisional.isEmpty && $0.messages.count == 5 }
        #expect(done.messages.map(\.role) == ["user", "assistant", "user", "assistant", "toolResult"])
        #expect(done.messages.map(\.entryID) == (0..<5).map { "m:\($0)" })
        #expect(done.messages[4].blocks.first?.text == "total 48\n")
        #expect(done.messages[4].startedAt == toolStarted, "history keeps the start time the host observed")
    }

    @Test func imagesTravelWithThePromptAndAreBounded() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let png = NativeImage(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let jpeg = NativeImage(mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))

        #expect(try await pi.send("look", images: [png, jpeg], from: s).failureCode == nil)
        let images = try #require(try await pi.waitForStdin("prompt")["images"] as? [[String: Any]])
        #expect(images.map { $0["mimeType"] as? String } == ["image/png", "image/jpeg"])
        #expect(images.first?["data"] as? String == png.data.base64EncodedString())

        let tooMany = Array(repeating: png, count: NativeImage.maxPerSend + 1)
        let tooLarge = [NativeImage(mimeType: "image/png", data: Data(count: NativeImage.maxBytes + 1))]
        let notAnImage = [NativeImage(mimeType: "text/plain", data: Data([1]))]
        for images in [tooMany, tooLarge, notAnImage] {
            #expect(try await pi.send("x", images: images, from: s).failureCode == "invalid")
        }
        _ = try await pi.send("plain", from: try await pi.snapshot { !$0.running })
        let plain = try await pi.waitForStdin("prompt", count: 2)
        #expect(plain["message"] as? String == "plain" && plain["images"] == nil)
    }

    @Test(arguments: ["", "  \n ", String(repeating: "x", count: RPCThreadState.textLimit + 1)])
    func sendRejectsBlankOrOversizedText(text: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        #expect(try await pi.send(text, from: s).failureCode == "invalid")
        #expect(pi.stdin("prompt").isEmpty)
    }

    /// The request budget is checked before anything reaches the thread.
    @Test func anOversizedRequestIsRefusedAtTheDoor() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let error = await #expect(throws: RemoteHostClientError.self) {
            _ = try await pi.send(String(repeating: "x", count: 64 * 1024), from: s)
        }
        guard case .rejected("native_limit", _)? = error else { Issue.record("expected native_limit, got \(String(describing: error))"); return }
    }

    // MARK: - Operation identity

    /// A retried operation replays its result; the same id with a different payload conflicts;
    /// pi sees one prompt.
    @Test func operationsAreIdempotentByID() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let op = UUID()

        #expect(try await pi.send("hello", operationID: op, from: s) == .accepted(operationID: op))
        #expect(try await pi.send("hello", operationID: op, from: s) == .accepted(operationID: op))
        #expect(try await pi.send("different", operationID: op, from: s)
            == .failure(code: "operation_conflict", message: "Operation ID was reused with a different payload."))
        _ = try await pi.snapshot("the turn to settle") { !$0.running && $0.messages.count == 5 }
        #expect(pi.stdin("prompt").count == 1)
    }

    @Test func actionsFromAnotherSessionOrGenerationAreStale() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        #expect(try await pi.request(.send(expectedSessionID: "other", generation: s.generation, operationID: UUID(), text: "x", delivery: .followUp)) == stale)
        #expect(try await pi.request(.abort(expectedSessionID: s.piSessionID, generation: UUID().uuidString, operationID: UUID())) == stale)
        #expect(pi.stdin("prompt").isEmpty && pi.stdin("abort").isEmpty)
    }

    /// pi moved to a new session: nothing from the old one may land in it.
    @Test func aSessionSwitchMintsANewGeneration() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        _ = try await pi.send("newsession", from: s)

        let switched = try await pi.snapshot("the new session") { $0.piSessionID == "stub-session-2" }
        #expect(switched.generation != s.generation)
        #expect(switched.messages.isEmpty)
        #expect(try await pi.send("late", from: s) == stale)
    }

    // MARK: - Abort, model, thinking

    @Test func abortReachesPiAndEndsTheRun() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        _ = try await pi.send("slow", from: s)
        let running = try await pi.snapshot("the turn to start") { $0.running }

        let op = UUID()
        #expect(try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: op)) == .accepted(operationID: op))
        _ = try await pi.waitForStdin("abort")
        _ = try await pi.snapshot("the run to end") { !$0.running }
        pi.release(1)
        pi.release(2)
    }

    @Test func setModelSplitsOnTheFirstSlashAndRefreshesTheThread() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let op = UUID()
        let request = NativeThreadRequest.setModel(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op, model: "anthropic/claude-opus-4/preview")

        #expect(try await pi.request(request) == .accepted(operationID: op))
        let wire = try await pi.waitForStdin("set_model")
        #expect(wire["provider"] as? String == "anthropic" && wire["modelId"] as? String == "claude-opus-4/preview")
        let changed = try await pi.snapshot("the model to refresh") { $0.model == "anthropic/claude-opus-4/preview" }
        #expect(changed.revision > s.revision)
    }

    @Test func setModelFailuresAreTyped() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        func setModel(_ model: String) async throws -> String? {
            try await pi.request(.setModel(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), model: model)).failureCode
        }
        #expect(try await setModel("nomodel") == "invalid")
        #expect(try await setModel("/leading") == "invalid")
        #expect(try await setModel("trailing/") == "invalid")
        #expect(try await setModel("nope/model") == "dispatch_failed", "pi rejected the provider")
        #expect(pi.stdin("set_model").count == 1)
    }

    @Test func setThinkingAcceptsOnlyKnownLevels() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let op = UUID()

        #expect(try await pi.request(.setThinking(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op, level: "high")) == .accepted(operationID: op))
        #expect(try await pi.waitForStdin("set_thinking_level")["level"] as? String == "high")
        _ = try await pi.snapshot("the thinking level to refresh") { $0.thinking == "high" }
        #expect(try await pi.request(.setThinking(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), level: "ultra")).failureCode == "invalid")
    }

    // MARK: - Questions

    @Test func aConfirmQuestionIsAnsweredOnce() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("ask", from: try await pi.ready())
        let asked = try await pi.snapshot("the question") { !$0.dialogs.isEmpty }
        #expect(asked.dialogs == [NativeThreadDialog(id: "uuid-2", kind: .confirm, title: "Clear session?", message: "All messages will be lost.", timeout: 60000)])
        #expect(asked.running)

        let op = UUID()
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: op, dialogID: "uuid-2", answer: .confirm(value: true))
        #expect(try await pi.request(answer) == .accepted(operationID: op))
        #expect(try await pi.waitForStdin("extension_ui_response")["confirmed"] as? Bool == true)
        let settled = try await pi.snapshot("the answered run to settle") { !$0.running && $0.dialogs.isEmpty }
        #expect(settled.dialogs.isEmpty)

        #expect(try await pi.request(answer) == .accepted(operationID: op), "a retry replays")
        #expect(pi.stdin("extension_ui_response").count == 1)
    }

    @Test func aSelectQuestionTakesAValueOrACancel() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("select", from: try await pi.ready())
        let asked = try await pi.snapshot("the select question") { !$0.dialogs.isEmpty }
        #expect(asked.dialogs.first?.options == ["Allow", "Deny"])
        _ = try await pi.request(.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID(), dialogID: "uuid-3", answer: .select(value: "Deny")))
        #expect(try await pi.waitForStdin("extension_ui_response")["value"] as? String == "Deny")

        _ = try await pi.send("select", from: try await pi.snapshot { !$0.running && $0.dialogs.isEmpty })
        let again = try await pi.snapshot("the second question") { !$0.dialogs.isEmpty }
        _ = try await pi.request(.answer(expectedSessionID: again.piSessionID, generation: again.generation, operationID: UUID(), dialogID: "uuid-3", answer: .cancel))
        let cancel = try await pi.waitForStdin("extension_ui_response", count: 2)
        #expect(cancel["cancelled"] as? Bool == true && cancel["value"] == nil)
    }

    @Test func answeringAQuestionThatIsNotPendingFails() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let result = try await pi.request(.answer(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), dialogID: "nope", answer: .confirm(value: true)))
        #expect(result == .failure(code: "dialog_unavailable", message: "Dialog answer not accepted. Refresh the thread."))
        #expect(pi.stdin("extension_ui_response").isEmpty)
    }

    // MARK: - History

    @Test func historyPagesNewestFirstByEntryCursor() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("fill", from: try await pi.ready())
        let page = try await pi.snapshot("the filled history") { $0.messages.last?.entryID == "m:121" }
        #expect(page.messages.map(\.entryID) == (72...121).map { "m:\($0)" })
        #expect(page.olderCursor == "m:72")

        let older = try #require(try await pi.request(.snapshot(beforeEntryID: "m:72")).snapshotValue)
        #expect(older.messages.map(\.entryID) == (22...71).map { "m:\($0)" })
        let oldest = try #require(try await pi.request(.snapshot(beforeEntryID: "m:22")).snapshotValue)
        #expect(oldest.messages.map(\.entryID) == (0...21).map { "m:\($0)" })
        #expect(oldest.olderCursor == nil)

        let staleCursor = NativeThreadResult.failure(code: "stale_cursor", message: "History changed. Refresh the recent page.")
        #expect(try await pi.request(.snapshot(beforeEntryID: "m:999")) == staleCursor)
        #expect(try await pi.request(.snapshot(beforeEntryID: "provisional:assistant:1")) == staleCursor)
    }

    /// Model-only customs and Shepherd's own child reports stay out; entry ids stay positional.
    @Test func subagentNoiseStaysOutOfTheTranscript() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("subagent-noise", from: try await pi.ready())
        let s = try await pi.snapshot("the noisy history") { $0.messages.last?.entryID == "m:8" }
        #expect(s.messages.map(\.entryID) == ["m:0", "m:1", "m:2", "m:3", "m:4", "m:6", "m:8"])
        #expect(s.messages.first { $0.entryID == "m:6" }?.blocks.first?.text == "A note the user should see")
        #expect(s.messages.first { $0.entryID == "m:3" }?.blocks.map(\.text) == ["Spawning."])
        #expect(s.messages.first { $0.entryID == "m:4" }?.argumentsText == #"{"action":"list"}"#)
        #expect(try await pi.request(.snapshot(beforeEntryID: "m:8")).snapshotValue?.messages.last?.entryID == "m:6")
    }

    // MARK: - Lifecycle

    @Test func aDeadAgentIsUnavailableAndStaysQueryableUntilRetired() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        _ = try? await pi.send("die", from: try await pi.ready())

        try await eventually("the exit callback") { callbacks.exited(pi.sessionID) }
        #expect(callbacks.exitCode(pi.sessionID) == .some(3))
        let error = await #expect(throws: RemoteHostClientError.self) { _ = try await pi.request(.snapshot()) }
        guard case .rejected("native_unavailable", _)? = error else { Issue.record("expected native_unavailable, got \(String(describing: error))"); return }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == false)
        await h.server.retireSession(sessionID: pi.sessionID)
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID) == nil)
    }

    @Test func anAgentWithoutAnRPCSessionIsUnavailable() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let shell = try await h.shell("sleep 30")
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, sessionID: shell.id)
        try await h.seed(Fixture.workspace([worker], space: space))
        let error = await #expect(throws: RemoteHostClientError.self) {
            _ = try await h.server.nativeThread(agentID: worker.agent.id, request: .snapshot())
        }
        guard case .rejected("native_unavailable", _)? = error else { Issue.record("got \(String(describing: error))"); return }
    }

    /// An RPC session has no terminal: terminal-only operations fail or do nothing, and raw
    /// input never reaches pi's stdin.
    @Test func terminalOperationsDoNotApplyToAnRPCSession() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()

        let error = await #expect(throws: SessionServerError.self) { _ = try await h.server.attachSnapshot(sessionID: pi.sessionID, replay: true) }
        #expect(error?.description == SessionServerError.noTerminal(pi.sessionID).description)
        h.server.write(sessionID: pi.sessionID, data: Data("{\"type\":\"abort\"}\n".utf8))
        h.server.resize(sessionID: pi.sessionID, cols: 10, rows: 5)
        h.server.reportLocalViewport(sessionID: pi.sessionID, cols: 10, rows: 5)
        h.server.detach(sessionID: pi.sessionID)
        #expect(await h.server.screenText(sessionID: pi.sessionID) == nil)
        #expect(await h.server.foregroundProcessName(sessionID: pi.sessionID) == nil)
        let info = try #require(await h.server.sessionInfo(sessionID: pi.sessionID))
        #expect(info.isAlive && info.cols == 0 && info.rows == 0)

        h.server.killSession(pi.sessionID)
        try await eventually("the kill to land") { callbacks.exited(pi.sessionID) }
        #expect(pi.stdin("abort").isEmpty)
    }

    // MARK: - Subagents

    /// The children extension publishes run cards; card actions go back to it as childCommand
    /// frames and are accepted only when it answers. The parent pi never sees them.
    @Test func subagentCardsAndTheirCommandsGoThroughTheChildrenExtension() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        #expect(s.subagents == [])
        let children = try ExtensionClient(path: h.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        let asking = ChildRun(runID: "native-2", label: "reviewer: check", state: "running", needsAttention: true,
                              question: ChildQuestion(text: "Two names collide", options: ["Replace everywhere", "Rename"]))
        let done = ChildRun(runID: "native-3", label: "tests: run", state: "complete", summary: "Added tests.")
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [asking, done]))
        let cards = try await pi.snapshot("the cards") { $0.subagents?.count == 2 }
        #expect(cards.subagents == [asking, done])
        #expect(cards.revision > s.revision)

        let op = UUID()
        let answer = NativeThreadRequest.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op,
                                                         runID: "native-2", action: .message, text: "Replace everywhere", mode: .steer)
        async let outcome = pi.request(answer)
        guard case .childCommand(let id, "native-2", .message, "Replace everywhere", .steer) = try await children.reply() else {
            Issue.record("expected the childCommand frame"); return
        }
        try children.send(.childCommandResult(id: id, error: nil))
        #expect(try await outcome == .accepted(operationID: op))
        #expect(try await pi.request(answer) == .accepted(operationID: op), "a retry replays without a second frame")
        #expect(pi.stdin("prompt").isEmpty)

        async let failing = pi.request(.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), runID: "native-3", action: .resume))
        guard case .childCommand(let failID, "native-3", .resume, nil, nil) = try await children.reply() else { Issue.record("expected resume"); return }
        try children.send(.childCommandResult(id: failID, error: "Child is not paused"))
        #expect(try await failing == .failure(code: "child_command_failed", message: "Child is not paused"))
    }

    @Test func subagentCommandsAreValidatedBeforeTheSocket() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let children = try ExtensionClient(path: h.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "native-1", label: "w", state: "running")]))
        _ = try await pi.snapshot("the card") { $0.subagents?.count == 1 }
        func command(_ runID: String, _ action: NativeSubagentAction, _ text: String? = nil, session: String? = nil) async throws -> String? {
            try await pi.request(.subagentCommand(expectedSessionID: session ?? s.piSessionID, generation: s.generation, operationID: UUID(),
                                                  runID: runID, action: action, text: text)).failureCode
        }
        #expect(try await command("nope", .cancel) == "unknown_run")
        #expect(try await command("native-1", .message, "  ") == "invalid")
        #expect(try await command("native-1", .message, String(repeating: "x", count: RPCThreadState.textLimit + 1)) == "invalid")
        #expect(try await command("native-1", .cancel, session: "stale") == "stale_session")
    }

    /// Without a children connection, or when it drops mid-command, the command fails instead of hanging.
    @Test func subagentCommandsFailWhenTheChildrenExtensionIsAbsentOrGone() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let children = try ExtensionClient(path: h.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "native-1", label: "w", state: "running")]))
        _ = try await pi.snapshot("the card") { $0.subagents?.count == 1 }
        func cancel() -> NativeThreadRequest {
            .subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), runID: "native-1", action: .cancel)
        }
        let first = cancel()
        async let orphan = pi.request(first)
        _ = try await children.reply()
        children.closeConnection()
        #expect(try await orphan.failureCode == "child_command_failed")
        #expect(try await pi.request(cancel()).failureCode == "child_command_failed")
    }

    @Test func aSubagentTranscriptPagesFromItsSessionFile() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let s = try await pi.ready()
        let file = h.dir.appendingPathComponent("child.jsonl")
        let lines = (0..<60).map { #"{"type":"message","id":"u\#($0)","message":{"role":"user","content":"step \#($0)"}}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let children = try ExtensionClient(path: h.socketPath)
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [
            ChildRun(runID: "native-1", label: "w", state: "complete", sessionFile: file.path),
            ChildRun(runID: "native-2", label: "no file", state: "running"),
        ]))
        _ = try await pi.snapshot("the cards") { $0.subagents?.count == 2 }

        guard case .transcript(let page) = try await pi.request(.subagentTranscript(expectedSessionID: s.piSessionID, runID: "native-1")) else {
            Issue.record("expected a transcript"); return
        }
        #expect(page.messages.count == 50 && page.earlierCount == 10 && page.messages.last?.entryID == "c:u59")
        #expect(try await pi.request(.subagentTranscript(expectedSessionID: s.piSessionID, runID: "native-2")).failureCode == "unknown_run")
        #expect(try await pi.request(.subagentTranscript(expectedSessionID: "stale", runID: "native-1")).failureCode == "stale_session")
    }
}

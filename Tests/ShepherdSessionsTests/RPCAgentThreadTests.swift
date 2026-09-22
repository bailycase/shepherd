import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions

/// The native-thread path for RPC agents: a real `SessionServer` on scratch
/// paths with an RPC session spawned from `Fixtures/stub-pi.py`.
@Suite("RPC agent native thread", .serialized)
struct RPCAgentThreadTests {
    static let stubPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stub-pi.py").path

    private struct Harness {
        let dir: URL
        let server: SessionServer
        let agent: Agent
        let sessionID: SessionID
        let logURL: URL

        init() async throws {
            dir = try makeScratchDirectory()
            logURL = dir.appendingPathComponent("stdin.log")
            server = SessionServer(socketPath: dir.appendingPathComponent("r.sock").path,
                                   stateURL: dir.appendingPathComponent("state.json"))
            try server.start()
            let space = Space(name: "rpc", path: dir.path)
            let session = try await server.createSession(params: CreateSessionParams(
                cwd: dir.path, command: ["python3", RPCAgentThreadTests.stubPath],
                env: ["STUB_PI_LOG": logURL.path], runtime: .rpc))
            sessionID = session.id
            let pane = LeafPane(sessionID: session.id, cwd: dir.path)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            agent = Agent(name: "rpc", spaceID: space.id, tabID: tab.id, paneID: pane.id)
            try await server.addSpace(space)
            try await server.addAgent(agent, withTab: tab)
        }

        func request(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            try await server.nativeThread(agentID: agent.id, request: request)
        }

        /// Poll until a snapshot satisfies `predicate`; returns the last snapshot seen.
        func snapshot(
            timeout: Duration = .seconds(30),
            where predicate: (NativeThreadSnapshot) -> Bool = { _ in true }
        ) async throws -> NativeThreadSnapshot {
            let deadline = ContinuousClock.now + timeout
            var last: NativeThreadSnapshot?
            while ContinuousClock.now < deadline {
                if case .snapshot(let value) = try await request(.snapshot()) {
                    last = value
                    if predicate(value) { return value }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return try #require(last, "no snapshot within \(timeout)")
        }

        /// The snapshot once the bootstrap responses (get_state + get_messages) have landed.
        func ready() async throws -> NativeThreadSnapshot {
            try await snapshot { !$0.piSessionID.isEmpty && !$0.messages.isEmpty }
        }

        func send(_ text: String, delivery: NativeThreadDelivery = .followUp, from current: NativeThreadSnapshot) async throws -> NativeThreadResult {
            try await request(.send(expectedSessionID: current.piSessionID, generation: current.generation,
                                    operationID: UUID(), text: text, delivery: delivery))
        }

        func stdinLines() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: logURL) else { return [] }
            return data.split(separator: UInt8(ascii: "\n")).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
        }

        /// The most recent stdin record of `type`, once the stub has logged one past `after`.
        func lastStdin(type: String, after count: Int = 0) async throws -> [String: Any] {
            _ = try await waitUntil { stdinLines().filter { $0["type"] as? String == type }.count > count }
            return try #require(stdinLines().last { $0["type"] as? String == type })
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func snapshotAfterSpawnReflectsStateMessagesAndCapabilities() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        #expect(s.piSessionID == "stub-session")
        #expect(s.model == "anthropic/claude-sonnet-4-20250514")
        #expect(s.thinking == "medium")
        #expect(!s.running)
        #expect(s.dialogsSupported)
        #expect(s.supportedActions == ["send", "abort", "answer", "setModel", "setThinking", "sendImages", "subagents"])
        #expect(s.runtime == "rpc")
        #expect(s.dialogs.isEmpty)
        #expect(s.widgets == [])
        #expect(s.provisional.isEmpty)
        #expect(s.olderCursor == nil)
        #expect(!s.clipped)
        #expect(s.messages.map(\.entryID) == ["m:0", "m:1"])
        #expect(s.messages.map(\.role) == ["user", "assistant"])
        #expect(s.messages[0].blocks == [NativeThreadBlock(kind: .text, text: "Hello!")])
        #expect(s.messages[1].status == "stop")
        #expect(UUID(uuidString: s.generation) != nil)
        // Bootstrap asked for everything in one go.
        #expect(try await waitUntil { Set(h.stdinLines().compactMap { $0["type"] as? String })
            .isSuperset(of: ["get_state", "get_messages", "get_commands", "get_session_stats"]) })

        // afterRevision on the current revision -> unchanged; a stale session id is rejected.
        #expect(try await h.request(.snapshot(afterRevision: s.revision))
            == .unchanged(piSessionID: s.piSessionID, generation: s.generation, revision: s.revision))
        guard case .snapshot(let again) = try await h.request(.snapshot(expectedSessionID: s.piSessionID, afterRevision: s.revision &- 1)) else {
            Issue.record("expected a snapshot for an older revision"); return
        }
        #expect(again.revision == s.revision)
        #expect(try await h.request(.snapshot(expectedSessionID: "other"))
            == .failure(code: "stale_session", message: "Refresh the thread before acting."))
    }

    @Test func sendStreamsProvisionalTextThenHistoryReplacesIt() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        guard case .accepted = try await h.send("slow", delivery: .steer, from: s) else {
            Issue.record("send not accepted"); return
        }
        // Idle agent: plain prompt, no streamingBehavior even though the client asked to steer.
        let prompt = try await h.lastStdin(type: "prompt")
        #expect(prompt["message"] as? String == "slow")
        #expect(prompt["streamingBehavior"] == nil)

        // Deltas accumulate into one provisional assistant message while the run is paused.
        let streaming = try await h.snapshot { $0.running && $0.provisional.contains { $0.blocks.first?.text == "Hello line\u{2028}sep" } }
        let partial = try #require(streaming.provisional.first)
        #expect(partial.entryID == "provisional:assistant:1")
        #expect(partial.role == "assistant")
        #expect(partial.status == "streaming")
        #expect(streaming.revision > s.revision)

        // A send while running carries the delivery mode.
        guard case .accepted = try await h.send("queued", delivery: .steer, from: streaming) else {
            Issue.record("steer not accepted"); return
        }
        let steer = try await h.lastStdin(type: "prompt", after: 1)
        #expect(steer["message"] as? String == "queued")
        #expect(steer["streamingBehavior"] as? String == "steer")

        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("continue-1").path, contents: nil)
        // Tool execution shows as running with its arguments, alongside the ended assistant message.
        let tooling = try await h.snapshot { $0.provisional.contains { $0.entryID == "provisional:tool:call_abc123" } }
        let assistant = try #require(tooling.provisional.first { $0.entryID == "provisional:assistant:1" })
        #expect(assistant.status == "toolUse")
        // The toolCall block is not prose; the tool row below carries the call.
        #expect(assistant.blocks.map(\.text) == ["Hello line\u{2028}sep world"])
        let tool = try #require(tooling.provisional.first { $0.entryID == "provisional:tool:call_abc123" })
        #expect(tool.role == "toolResult")
        #expect(tool.status == "running")
        #expect(tool.toolName == "bash")
        #expect(tool.toolCallID == "call_abc123")
        #expect(tool.argumentsText == "{\"command\":\"ls\"}")
        #expect(tool.blocks.isEmpty)

        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("continue-2").path, contents: nil)
        // After agent_end the history refresh replaces every provisional item.
        let done = try await h.snapshot { !$0.running && $0.provisional.isEmpty && $0.messages.count == 5 }
        #expect(done.messages.map(\.role) == ["user", "assistant", "user", "assistant", "toolResult"])
        #expect(done.messages[2].blocks.first?.text == "slow")
        #expect(done.messages[3].status == "toolUse")
        #expect(done.messages[4].toolCallID == "call_abc123")
        #expect(done.messages[4].blocks.first?.text == "total 48\n")
        #expect(done.messages[4].isError == false)
        #expect(done.messages.map(\.entryID) == (0..<5).map { "m:\($0)" })
    }

    @Test func toolExecutionCompletesBeforeHistoryCatchesUp() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        _ = try await h.send("hello", from: s)
        // The fast turn goes straight through; the settled state carries the tool result as history.
        let done = try await h.snapshot { !$0.running && $0.messages.count == 5 }
        #expect(done.provisional.isEmpty)
        #expect(done.messages[4].status == nil)
    }

    @Test func dialogAppearsAndAnswerReachesPi() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        _ = try await h.send("ask", from: s)
        let asked = try await h.snapshot { !$0.dialogs.isEmpty }
        let dialog = try #require(asked.dialogs.first)
        #expect(dialog == NativeThreadDialog(id: "uuid-2", kind: .confirm, title: "Clear session?",
                                             message: "All messages will be lost.", timeout: 5000))
        #expect(asked.running)

        // Unknown dialog id -> dialog_unavailable, and it is still pending.
        let missing = try await h.request(.answer(expectedSessionID: asked.piSessionID, generation: asked.generation,
                                                  operationID: UUID(), dialogID: "nope", answer: .confirm(value: true)))
        #expect(missing == .failure(code: "dialog_unavailable", message: "Dialog answer not accepted. Refresh the thread."))

        let op = UUID()
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation,
                                                operationID: op, dialogID: dialog.id, answer: .confirm(value: true))
        #expect(try await h.request(answer) == .accepted(operationID: op))
        let response = try await h.lastStdin(type: "extension_ui_response")
        #expect(response["id"] as? String == "uuid-2")
        #expect(response["confirmed"] as? Bool == true)
        let answered = try await h.snapshot { $0.dialogs.isEmpty && !$0.running }
        #expect(answered.dialogs.isEmpty)

        // Replaying the same operation returns the same result; a different payload conflicts.
        #expect(try await h.request(answer) == .accepted(operationID: op))
        let conflict = try await h.request(.answer(expectedSessionID: asked.piSessionID, generation: asked.generation,
                                                   operationID: op, dialogID: dialog.id, answer: .cancel))
        #expect(conflict == .failure(code: "operation_conflict", message: "Operation ID was reused with a different payload."))
        // Only one response went to pi.
        #expect(h.stdinLines().filter { $0["type"] as? String == "extension_ui_response" }.count == 1)
    }

    @Test func selectAnswerAndCancelMapToValueAndCancelled() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        _ = try await h.send("select", from: s)
        let asked = try await h.snapshot { !$0.dialogs.isEmpty }
        let dialog = try #require(asked.dialogs.first)
        #expect(dialog.kind == .select)
        #expect(dialog.options == ["Allow", "Deny"])
        #expect(dialog.timeout == nil)
        _ = try await h.request(.answer(expectedSessionID: asked.piSessionID, generation: asked.generation,
                                        operationID: UUID(), dialogID: dialog.id, answer: .select(value: "Deny")))
        let response = try await h.lastStdin(type: "extension_ui_response")
        #expect(response["value"] as? String == "Deny")
        let done = try await h.snapshot { !$0.running && $0.dialogs.isEmpty }
        #expect(done.dialogs.isEmpty)

        _ = try await h.send("select", from: done)
        let again = try await h.snapshot { !$0.dialogs.isEmpty }
        _ = try await h.request(.answer(expectedSessionID: again.piSessionID, generation: again.generation,
                                        operationID: UUID(), dialogID: "uuid-3", answer: .cancel))
        let cancel = try await h.lastStdin(type: "extension_ui_response", after: 1)
        #expect(cancel["cancelled"] as? Bool == true)
        #expect(cancel["value"] == nil)
    }

    @Test func staleGenerationOrSessionIsRejectedAndOperationsAreIdempotent() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        let stale = "Refresh the thread before acting."
        #expect(try await h.request(.send(expectedSessionID: "other", generation: s.generation, operationID: UUID(),
                                          text: "x", delivery: .followUp)) == .failure(code: "stale_session", message: stale))
        #expect(try await h.request(.abort(expectedSessionID: s.piSessionID, generation: UUID().uuidString, operationID: UUID()))
            == .failure(code: "stale_session", message: stale))
        #expect(try await h.request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                          text: "   ", delivery: .followUp)).isFailure(code: "invalid"))

        let op = UUID()
        let send = NativeThreadRequest.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op,
                                            text: "hello", delivery: .followUp)
        #expect(try await h.request(send) == .accepted(operationID: op))
        #expect(try await h.request(send) == .accepted(operationID: op))
        #expect(try await h.request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op,
                                          text: "different", delivery: .followUp))
            == .failure(code: "operation_conflict", message: "Operation ID was reused with a different payload."))
        _ = try await h.lastStdin(type: "prompt")
        #expect(h.stdinLines().filter { $0["type"] as? String == "prompt" }.count == 1)

        // Abort goes through and pi answers.
        let abortOp = UUID()
        #expect(try await h.request(.abort(expectedSessionID: s.piSessionID, generation: s.generation, operationID: abortOp))
            == .accepted(operationID: abortOp))
        #expect(h.stdinLines().contains { $0["type"] as? String == "abort" })
    }

    @Test func widgetsStripANSIAndClear() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        _ = try await h.send("widgets", from: s)
        let shown = try await h.snapshot { ($0.widgets ?? []).count == 1 }
        let widgets = try #require(shown.widgets)
        #expect(widgets == [NativeThreadWidget(namespace: "pi", key: "w", kind: .text, text: "Bold line\nlink")])
        // setStatus is TUI footer chrome and notify is a toast: neither shows. Nor does
        // setTitle, nor a machine-readable widget payload meant for an extension's own component.

        _ = try await h.send("widgets-clear", from: shown)
        let cleared = try await h.snapshot { ($0.widgets ?? []).isEmpty }
        #expect(cleared.revision > shown.revision)
    }

    @Test func subagentNoiseStaysOutOfTheTranscript() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        _ = try await h.send("subagent-noise", from: s)
        let shown = try await h.snapshot { $0.messages.contains { $0.entryID == "m:8" } }
        let roles = shown.messages.map(\.role)
        // 2 seeded + 7 appended, minus the display:false custom and Shepherd's child report
        // (the cards own it) → 7 rows; ids stay positional.
        #expect(shown.messages.count == 7)
        #expect(!shown.messages.contains { $0.blocks.contains { $0.text.hasPrefix("Child native-1") } })
        #expect(!roles.contains("custom") || shown.messages.contains { $0.role == "custom" && $0.blocks.first?.text == "A note the user should see" })
        #expect(!shown.messages.contains { $0.blocks.contains { $0.text.contains("Background task completed") } })
        // The assistant's toolCall block is not rendered as prose; the tool row carries it.
        let assistant = try #require(shown.messages.first { $0.entryID == "m:3" })
        #expect(assistant.blocks.map(\.text) == ["Spawning."])
        #expect(shown.messages.contains { $0.toolName == "subagent" && $0.argumentsText?.contains("list") == true })
        // A cursor into filtered history still resolves by id.
        guard case .snapshot(let older) = try await h.request(.snapshot(expectedSessionID: shown.piSessionID, beforeEntryID: "m:8")) else {
            Issue.record("expected older page"); return
        }
        #expect(older.messages.last?.entryID == "m:6")
    }

    @Test func pagingWithBeforeEntryID() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        _ = try await h.send("fill", from: s)
        // 2 seeded + 120 filler = 122 messages, m:0 ... m:121, newest page first.
        let page = try await h.snapshot { $0.messages.count == 50 }
        #expect(page.messages.first?.entryID == "m:72")
        #expect(page.messages.last?.entryID == "m:121")
        #expect(page.olderCursor == "m:72")

        guard case .snapshot(let older) = try await h.request(.snapshot(expectedSessionID: page.piSessionID, beforeEntryID: "m:72")) else {
            Issue.record("expected older page"); return
        }
        #expect(older.messages.first?.entryID == "m:22")
        #expect(older.messages.last?.entryID == "m:71")
        #expect(older.olderCursor == "m:22")
        guard case .snapshot(let oldest) = try await h.request(.snapshot(expectedSessionID: page.piSessionID, beforeEntryID: "m:22")) else {
            Issue.record("expected oldest page"); return
        }
        #expect(oldest.messages.map(\.entryID) == (0..<22).map { "m:\($0)" })
        #expect(oldest.olderCursor == nil)
        #expect(try await h.request(.snapshot(beforeEntryID: "m:999"))
            == .failure(code: "stale_cursor", message: "History changed. Refresh the recent page."))
        #expect(try await h.request(.snapshot(beforeEntryID: "provisional:assistant:1"))
            == .failure(code: "stale_cursor", message: "History changed. Refresh the recent page."))
    }

    @Test func sessionSwitchMintsANewGeneration() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        _ = try await h.send("newsession", from: s)
        let switched = try await h.snapshot { $0.piSessionID == "stub-session-2" }
        #expect(switched.generation != s.generation)
        #expect(switched.messages.isEmpty)
        #expect(try await h.request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                          text: "late", delivery: .followUp)).isFailure(code: "stale_session"))
    }

    @Test func processDeathReportsExitAndNativeUnavailable() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let exited = Locked<(SessionID, Int32?)?>(nil)
        h.server.onSessionExited = { id, code in exited.withValue { $0 = (id, code) } }
        let s = try await h.ready()
        _ = try? await h.send("die", from: s)
        #expect(try await waitUntil { exited.current != nil })
        #expect(exited.current?.0 == h.sessionID)
        #expect(exited.current?.1 == 3)
        #expect(await h.server.sessionInfo(sessionID: h.sessionID)?.isAlive == false)
        do {
            _ = try await h.request(.snapshot())
            Issue.record("dead RPC session accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "native_unavailable") }
        await h.server.retireSession(sessionID: h.sessionID)
        #expect(await h.server.sessionInfo(sessionID: h.sessionID) == nil)
    }

    @Test func terminalOnlyOperationsFailCleanlyOnRPCSessions() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        _ = try await h.ready()
        do {
            _ = try await h.server.attachSnapshot(sessionID: h.sessionID, replay: true)
            Issue.record("attach to an RPC session succeeded")
        } catch SessionServerError.noTerminal(let id) { #expect(id == h.sessionID) }
        h.server.write(sessionID: h.sessionID, data: Data("{\"type\":\"abort\"}\n".utf8))
        h.server.resize(sessionID: h.sessionID, cols: 10, rows: 5)
        h.server.reportLocalViewport(sessionID: h.sessionID, cols: 10, rows: 5)
        h.server.detach(sessionID: h.sessionID)
        #expect(await h.server.screenText(sessionID: h.sessionID) == nil)
        #expect(await h.server.foregroundProcessName(sessionID: h.sessionID) == nil)
        let info = try #require(await h.server.sessionInfo(sessionID: h.sessionID))
        #expect(info.isAlive)
        #expect(info.cols == 0 && info.rows == 0)
        // Raw input never reached pi's stdin.
        #expect(!h.stdinLines().contains { $0["type"] as? String == "abort" })
        let exited = Locked(false)
        h.server.onSessionExited = { _, _ in exited.withValue { $0 = true } }
        h.server.killSession(h.sessionID)
        #expect(try await waitUntil { exited.current })
        #expect(await h.server.sessionInfo(sessionID: h.sessionID)?.isAlive == false)
    }

    // MARK: v2 (rpc-agents-plan step 4)

    @Test func statsAndCommandsAreProjectedFromPi() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.snapshot { $0.stats != nil && $0.commands != nil }
        #expect(s.stats == NativeThreadStats(contextTokens: 60000, contextWindow: 200000, contextPercent: 30, totalTokens: 105000, cost: 0.45))
        #expect(s.commands == [
            NativeCommand(name: "session-name", description: "Set or clear session name", source: "extension"),
            NativeCommand(name: "fix-tests", description: "Fix failing tests", source: "prompt"),
        ])
        // Wire shape: v1 clients ignore the new keys; the encoded snapshot round-trips.
        let encoded = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(NativeThreadSnapshot.self, from: encoded) == s)

        // Limits: count cap, name cap drops, description clipped.
        let items: [JSONValue] = (0..<200).map { i in
            .object(["name": .string(i == 0 ? String(repeating: "n", count: 65) : "c\(i)"),
                     "description": .string(String(repeating: "d", count: 300)), "source": .string("skill")])
        }
        let projected = RPCThreadState.projectCommands(.array(items))
        #expect(projected.count == NativeCommand.maxCount)
        #expect(projected.first?.name == "c1")
        #expect(projected.first?.description?.utf8.count == NativeCommand.maxDescriptionBytes)
        #expect(RPCThreadState.projectCommands(nil).isEmpty)
    }

    @Test func setModelAndThinkingReachPiAndRefreshState() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        let op = UUID()
        let setModel = NativeThreadRequest.setModel(expectedSessionID: s.piSessionID, generation: s.generation,
                                                    operationID: op, model: "anthropic/claude-opus-4/preview")
        #expect(try await h.request(setModel) == .accepted(operationID: op))
        let wire = try await h.lastStdin(type: "set_model")
        // Split on the first slash only: model ids may contain one.
        #expect(wire["provider"] as? String == "anthropic")
        #expect(wire["modelId"] as? String == "claude-opus-4/preview")
        let changed = try await h.snapshot { $0.model == "anthropic/claude-opus-4/preview" }
        #expect(changed.revision > s.revision)
        // Same operation replays; a reused id with another model conflicts.
        #expect(try await h.request(setModel) == .accepted(operationID: op))
        #expect(try await h.request(.setModel(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op, model: "anthropic/x"))
            .isFailure(code: "operation_conflict"))
        // pi rejects unknown providers -> dispatch_failed; a bare id is invalid before reaching pi.
        #expect(try await h.request(.setModel(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), model: "nope/model"))
            .isFailure(code: "dispatch_failed"))
        #expect(try await h.request(.setModel(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), model: "nomodel"))
            .isFailure(code: "invalid"))
        #expect(try await h.request(.setModel(expectedSessionID: "stale", generation: s.generation, operationID: UUID(), model: "anthropic/x"))
            .isFailure(code: "stale_session"))

        let thinkOp = UUID()
        #expect(try await h.request(.setThinking(expectedSessionID: s.piSessionID, generation: s.generation, operationID: thinkOp, level: "high"))
            == .accepted(operationID: thinkOp))
        #expect(try await h.lastStdin(type: "set_thinking_level")["level"] as? String == "high")
        _ = try await h.snapshot { $0.thinking == "high" }
        #expect(try await h.request(.setThinking(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), level: "ultra"))
            .isFailure(code: "invalid"))
        #expect(h.stdinLines().filter { $0["type"] as? String == "set_model" }.count == 2)
    }

    @Test func imagesTravelWithThePromptAndAreBounded() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        let png = NativeImage(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let jpeg = NativeImage(mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let op = UUID()
        let send = NativeThreadRequest.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op,
                                            text: "look", delivery: .followUp, images: [png, jpeg])
        #expect(try await h.request(send) == .accepted(operationID: op))
        let prompt = try await h.lastStdin(type: "prompt")
        let images = try #require(prompt["images"] as? [[String: Any]])
        #expect(images.map { $0["type"] as? String } == ["image", "image"])
        #expect(images.map { $0["mimeType"] as? String } == ["image/png", "image/jpeg"])
        #expect(images.first?["data"] as? String == png.data.base64EncodedString())
        let logged = try await h.lastStdin(type: "stub-images")
        #expect(logged["count"] as? Int == 2)
        _ = try await h.snapshot { !$0.running && $0.messages.count == 5 }

        // Too many, too large, or not an image -> invalid, nothing written.
        let before = h.stdinLines().filter { $0["type"] as? String == "prompt" }.count
        let five = Array(repeating: png, count: NativeImage.maxPerSend + 1)
        #expect(try await h.request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                          text: "x", delivery: .followUp, images: five)).isFailure(code: "invalid"))
        let huge = NativeImage(mimeType: "image/png", data: Data(count: NativeImage.maxBytes + 1))
        #expect(try await h.request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                          text: "x", delivery: .followUp, images: [huge])).isFailure(code: "invalid"))
        #expect(try await h.request(.send(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                          text: "x", delivery: .followUp, images: [NativeImage(mimeType: "text/plain", data: Data([1]))]))
            .isFailure(code: "invalid"))
        #expect(h.stdinLines().filter { $0["type"] as? String == "prompt" }.count == before)
        // A plain send still omits the key entirely.
        _ = try await h.send("plain", from: try await h.snapshot { !$0.running })
        let plain = try await h.lastStdin(type: "prompt", after: before)
        #expect(plain["images"] == nil)
    }

    /// Native child runs published over the socket (a fake children extension) land in the RPC
    /// snapshot as cards; card actions travel back to that extension as childCommand frames;
    /// the transcript pages from the child's session file.
    @Test func subagentCardsCommandsAndTranscript() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let s = try await h.ready()
        #expect(s.supportedActions.contains("subagents"))
        #expect(s.subagents == [])

        // A synthetic child session: 60 user/assistant pairs plus a tool call and a model-only custom.
        let sessionFile = h.dir.appendingPathComponent("child-session.jsonl")
        var lines = [#"{"type":"session","id":"child","version":3,"cwd":"/tmp"}"#]
        for i in 0..<60 {
            lines.append(#"{"type":"message","id":"u\#(i)","message":{"role":"user","content":"step \#(i)"}}"#)
            lines.append(#"{"type":"message","id":"a\#(i)","message":{"role":"assistant","content":[{"type":"text","text":"reply \#(i)"}],"stopReason":"stop"}}"#)
        }
        lines.append(#"{"type":"message","id":"c1","message":{"role":"custom","customType":"x","display":false,"content":[{"type":"text","text":"hidden"}]}}"#)
        lines.append(#"{"type":"message","id":"t0","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_e","name":"edit","arguments":{"path":"A.swift"}}],"stopReason":"toolUse"}}"#)
        lines.append(#"{"type":"message","id":"t1","message":{"role":"toolResult","toolCallId":"call_e","toolName":"edit","content":[{"type":"text","text":"ok"}],"isError":false}}"#)
        lines.append(#"{"type":"model_change","id":"m","provider":"p","modelId":"m"}"#)
        try (lines.joined(separator: "\n") + "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let children = try ExtensionClient(path: h.dir.appendingPathComponent("r.sock").path)
        try children.send(.helloChildren(agentID: h.agent.id))
        let running = ChildRun(runID: "native-1", label: "worker: restyle", state: "running", startedAt: 1000, needsAttention: false, asyncDir: "/tmp/c",
                               role: "worker", model: "anthropic/claude-fable-5-1", thinking: "high", context: "background", turns: 78, toolCalls: 82, tokens: 922_000,
                               lastActivity: ChildActivity(tool: "edit", preview: "Sources/A.swift", diff: ChildDiff(added: 31, removed: 0), at: 2000),
                               toolCallID: "call_abc123", task: "Restyle the native thread", sessionFile: sessionFile.path)
        let asking = ChildRun(runID: "native-2", label: "reviewer: check", state: "running", needsAttention: true, attentionText: "Two names collide",
                              role: "reviewer", question: ChildQuestion(text: "Two names collide", options: ["Replace everywhere", "Rename new ones"]))
        let done = ChildRun(runID: "native-3", label: "tests: run", state: "complete", startedAt: 1000, endedAt: 243_000, role: "tests",
                            result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000), output: "Added 6 presentation tests.",
                            files: [ChildFileChange(path: "Tests/A.swift", added: 96, removed: 3)], summary: "Added 6 presentation tests.", sessionID: "child", cwd: "/tmp")
        try children.send(.setAgentChildren(agentID: h.agent.id, children: [running, asking, done]))
        let withCards = try await h.snapshot { $0.subagents?.count == 3 }
        #expect(withCards.revision > s.revision)
        #expect(withCards.subagents?.first?.toolCallID == "call_abc123")
        #expect(withCards.subagents?[1].question?.options == ["Replace everywhere", "Rename new ones"])
        #expect(withCards.subagents?[2].result?.added == 96)
        // Completed-run fields ride the same publish into the snapshot (ledger rows, RESULT block, Fork).
        #expect(withCards.subagents?[2].files == [ChildFileChange(path: "Tests/A.swift", added: 96, removed: 3)])
        #expect(withCards.subagents?[2].summary == "Added 6 presentation tests." && withCards.subagents?[2].sessionID == "child" && withCards.subagents?[2].cwd == "/tmp")

        // Answering a needs-you card: validated by the thread state, dispatched to the children
        // extension as a childCommand, and only accepted once the extension answers.
        let op = UUID()
        let answer = NativeThreadRequest.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: op,
                                                         runID: "native-2", action: .message, text: "Replace everywhere", mode: .steer)
        async let outcome = h.request(answer)
        let frame = try children.readReply()
        guard case .childCommand(let id, let runID, let action, let text, let mode) = frame else {
            Issue.record("expected childCommand, got \(frame)"); return
        }
        #expect(runID == "native-2" && action == .message && text == "Replace everywhere" && mode == .steer)
        try children.send(.childCommandResult(id: id, error: nil))
        #expect(try await outcome == .accepted(operationID: op))
        // The parent pi never saw a prompt for it.
        #expect(!h.stdinLines().contains { $0["type"] as? String == "prompt" })
        // Same operation replays without a second frame; a failure text becomes a failure result.
        #expect(try await h.request(answer) == .accepted(operationID: op))
        async let failing = h.request(.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                                          runID: "native-1", action: .cancel))
        guard case .childCommand(let cancelID, _, .cancel, nil, nil) = try children.readReply() else { Issue.record("expected cancel"); return }
        try children.send(.childCommandResult(id: cancelID, error: "Child is not running"))
        #expect(try await failing.isFailure(code: "child_command_failed"))
        // Guards that never reach the socket.
        #expect(try await h.request(.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                                     runID: "nope", action: .cancel)).isFailure(code: "unknown_run"))
        #expect(try await h.request(.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                                     runID: "native-2", action: .message, text: "  ")).isFailure(code: "invalid"))
        #expect(try await h.request(.subagentCommand(expectedSessionID: "stale", generation: s.generation, operationID: UUID(),
                                                     runID: "native-2", action: .cancel)).isFailure(code: "stale_session"))

        // Transcript: newest 50 of 122 visible entries (the model-only custom is filtered), then paging.
        guard case .transcript(let page) = try await h.request(.subagentTranscript(expectedSessionID: s.piSessionID, runID: "native-1")) else {
            Issue.record("expected transcript"); return
        }
        #expect(page.runID == "native-1" && page.messages.count == 50 && page.earlierCount == 72)
        #expect(page.messages.last?.entryID == "c:t1" && page.messages.last?.toolName == "edit")
        #expect(page.messages.last?.argumentsText == #"{"path":"A.swift"}"#)
        #expect(!page.messages.contains { $0.role == "custom" })
        #expect(page.olderCursor == page.messages.first?.entryID)
        guard case .transcript(let older) = try await h.request(.subagentTranscript(expectedSessionID: s.piSessionID, runID: "native-1", beforeEntryID: page.olderCursor)) else {
            Issue.record("expected older page"); return
        }
        #expect(older.messages.count == 50 && older.earlierCount == 22 && older.messages.last?.entryID != page.messages.first?.entryID)
        guard case .transcript(let oldest) = try await h.request(.subagentTranscript(expectedSessionID: s.piSessionID, runID: "native-1", beforeEntryID: older.olderCursor)) else {
            Issue.record("expected oldest page"); return
        }
        #expect(oldest.messages.count == 22 && oldest.olderCursor == nil && oldest.messages.first?.entryID == "c:u0")
        #expect(try await h.request(.subagentTranscript(expectedSessionID: s.piSessionID, runID: "native-1", beforeEntryID: "c:gone")).isFailure(code: "stale_cursor"))
        #expect(try await h.request(.subagentTranscript(expectedSessionID: s.piSessionID, runID: "native-2")).isFailure(code: "unknown_run"))

        // The children connection going away fails the command instead of hanging it.
        async let orphan = h.request(.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                                         runID: "native-3", action: .resume))
        _ = try children.readReply()
        children.closeConnection()
        #expect(try await orphan.isFailure(code: "child_command_failed"))
        #expect(try await h.request(.subagentCommand(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                                     runID: "native-3", action: .resume)).isFailure(code: "child_command_failed"))
    }
}

private extension NativeThreadResult {
    func isFailure(code: String) -> Bool {
        if case .failure(let c, _) = self { return c == code }
        return false
    }
}

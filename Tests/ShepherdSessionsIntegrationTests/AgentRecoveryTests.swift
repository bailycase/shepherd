import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

private final class RestartPreparationGate: @unchecked Sendable {
    // Scratch server queue owned.
    var pending: (() -> Void)?
}

@Suite("Durable ordinary agent recovery", .integrationTimeLimit)
struct AgentRecoveryTests {
    private func store(_ host: ScratchServer) -> AgentRecoveryStore {
        AgentRecoveryStore(directory: host.dir.appendingPathComponent("agent-recovery"))
    }

    private func resume(_ original: PiAgent, on host: ScratchServer, env: [String: String] = [:]) async throws -> PiAgent {
        let log = host.dir.appendingPathComponent("resumed-\(UUID().uuidString).log")
        let session = try await host.server.createSession(params: CreateSessionParams(
            cwd: host.dir.path, command: StubPi.command,
            env: env.merging(["STUB_PI_LOG": log.path, "SHEPHERD_AGENT_ID": original.agent.id.rawValue]) { $1 }, runtime: .rpc),
            resuming: "stub-session")
        var tab = try #require(host.server.state.tabs.first { $0.id == original.agent.tabID })
        tab.layout = tab.layout.updatingLeaf(try #require(original.agent.paneID)) { $0.sessionID = session.id }
        try await host.server.updateTab(tab)
        return PiAgent(host: host, agent: original.agent, sessionID: session.id, log: log)
    }

    @Test func workingAgentsAndTheirQueueSurviveAnAppRestart() async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        _ = try await pi.send("slow", from: idle)
        let working = try await pi.snapshot { $0.running && !$0.provisional.isEmpty }
        let image = NativeImage(mimeType: "image/png", data: Data([137, 80, 78, 71]))
        _ = try await pi.send("queued work", images: [image], from: working)
        let saved = try #require(try store(h).checkpoint(for: pi.agent.id))
        #expect(saved.active && saved.items.first?.entry.text == "queued work")
        #expect(await h.server.agentsNeedingStartupRecovery() == [pi.agent.id])
        #expect(try store(h).checkpoint(for: pi.agent.id) == saved, "Admission does not consume a recovery attempt")
        #expect(saved.items.first?.images == [image])
        h.stop(keepFiles: true)
        #expect(try store(h).checkpoint(for: pi.agent.id) == saved, "Shutdown must not replace active intent with idle")

        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        let continuation = try await restored.waitForStdin("resume_session")
        #expect(continuation["message"] == nil)
        let queued = try await restored.waitForStdin("prompt")
        #expect(queued["message"] as? String == "queued work")
        let images = try #require(queued["images"] as? [[String: Any]])
        #expect(images.first?["data"] as? String == image.data.base64EncodedString())
        _ = try await restored.snapshot { !$0.running && $0.queue?.items.isEmpty != false && !$0.provisional.contains { $0.entryID.hasPrefix("pending:") } }
        try await eventually("the settled checkpoint to clear") { try store(restarted).checkpoint(for: pi.agent.id) == nil }
    }

    @Test func explicitStopKeepsQueuedWorkPausedAfterRestart() async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }
        _ = try await pi.send("stay queued", from: working)
        _ = try await pi.request(.abort(expectedSessionID: working.piSessionID, generation: working.generation, operationID: UUID()))
        let paused = try await pi.snapshot { !$0.running && $0.queue?.paused == true }
        #expect(paused.queue?.items.first?.text == "stay queued")
        #expect(await h.server.agentsNeedingStartupRecovery().isEmpty)
        h.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        let ready = try await restored.ready()
        #expect(ready.queue?.paused == true && ready.queue?.items.first?.text == "stay queued")
        #expect(restored.stdin("prompt").isEmpty)
    }

    @Test(arguments: ["idle", "settled", "question", "stopped"])
    func idleWaitingSettledAndStoppedAgentsDoNotContinue(mode: String) async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        if mode == "question" {
            _ = try await pi.send("question", from: idle)
            _ = try await pi.snapshot { !$0.dialogs.isEmpty }
        } else if mode != "idle" {
            _ = try await pi.send(mode == "stopped" ? "slow" : "hello", from: idle)
            if mode == "stopped" {
                let working = try await pi.snapshot { $0.running }
                _ = try await pi.request(.abort(expectedSessionID: working.piSessionID, generation: working.generation, operationID: UUID()))
            }
            _ = try await pi.snapshot { !$0.running && !$0.provisional.contains { $0.entryID.hasPrefix("pending:") } }
        }
        #expect(try store(h).checkpoint(for: pi.agent.id) == nil)
        #expect(await h.server.agentsNeedingStartupRecovery().isEmpty)
        h.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        _ = try await restored.ready()
        #expect(restored.stdin("prompt").isEmpty)
    }

    @Test(arguments: [AgentRecoveryStore.attemptLimit - 1, AgentRecoveryStore.attemptLimit], [false, true])
    func recoveryAttemptsAreDurablyBoundedEvenWithAPausedQueue(previousAttempts: Int, paused: Bool) async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        try store(h).save(.init(sessionID: "stub-session", active: true, items: [], pending: [], paused: paused,
                               mode: .oneAtATime, attempts: previousAttempts), for: pi.agent.id)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let admitted = await restarted.server.agentsNeedingStartupRecovery()
        #expect(admitted == (previousAttempts < AgentRecoveryStore.attemptLimit ? [pi.agent.id] : []),
                "A paused queue does not cancel its active turn's authorized recovery")
        let restored = try await resume(pi, on: restarted)
        _ = try await restored.ready()
        if previousAttempts < AgentRecoveryStore.attemptLimit {
            _ = try await restored.waitForStdin("resume_session")
            #expect(restored.stdin("prompt").isEmpty)
        } else {
            #expect(restored.stdin("prompt").isEmpty && restored.stdin("resume_session").isEmpty, "No fourth automatic continuation")
        }
    }

    @Test func anUncleanCheckpointRecoversASendNotYetConsumedByPi() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:0 hold-start", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running && $0.provisional.contains { $0.entryID.hasPrefix("pending:") } }
        let checkpoint = try #require(try store(h).checkpoint(for: pi.agent.id))
        #expect(checkpoint.pending.first?.entry.text == "tools:0 hold-start")
        // Copy only durable files before shutdown: the snapshot gets no graceful-quit callbacks.
        let crashDirectory = try makeScratchDirectory("recover")
        try FileManager.default.copyItem(at: h.stateURL, to: crashDirectory.appendingPathComponent("state.json"))
        try FileManager.default.copyItem(at: h.dir.appendingPathComponent("agent-recovery"),
                                        to: crashDirectory.appendingPathComponent("agent-recovery"))
        h.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: crashDirectory)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        let paused = try await restored.snapshot { $0.queue?.paused == true }
        #expect(paused.queue?.items.first?.text == "tools:0 hold-start")
        #expect(restored.stdin("prompt").isEmpty)
        #expect(restored.stdin("resume_session").isEmpty, "Unknown input delivery must not cause a continuation")
    }

    @Test func heldQueueEditsWaitWhileTheInterruptedTurnRecovers() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }
        _ = try await pi.send("being edited", from: working)
        let queued = try await pi.snapshot { $0.queue?.items.count == 1 }
        _ = try await pi.queue(.hold(id: try #require(queued.queue?.items.first?.id), held: true), from: queued)
        h.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        _ = try await restored.waitForStdin("resume_session")
        let settled = try await restored.snapshot { !$0.running && $0.queue?.paused == true }
        #expect(settled.queue?.items.first?.text == "being edited")
        #expect(restored.stdin("prompt").isEmpty, "Recover the turn without injecting input or sending the unfinished queue edit")
    }

    @Test(arguments: ["automation", "goal"])
    func featureOwnedWorkDoesNotCreateOrdinaryRecovery(kind: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        h.server.setGoalsEnabled(true)
        let goalFile = h.dir.appendingPathComponent("goal.json")
        let goal = NativeGoal(id: GoalProjectionTests.id, text: "finish", state: .working, tokensUsed: 0)
        try JSONEncoder().encode(goal).write(to: goalFile)
        let env = kind == "goal" ? ["STUB_PI_GOAL_FILE": goalFile.path, "SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "1"] : [:]
        let pi = try await PiAgent.launch(on: h, env: env)
        if kind == "automation" {
            try await h.server.addAutomation(Automation(name: "watch", prompt: "work", cwd: h.dir.path, agentID: pi.agent.id))
        } else {
            _ = try await pi.snapshot { $0.goal == goal }
        }
        _ = try await pi.send("slow", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        #expect(try store(h).checkpoint(for: pi.agent.id) == nil)
    }

    @Test func anOpeningPromptIsCheckpointedBeforeBootstrapAndSentOnlyOnce() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_STARTUP_GATE": "boot"])
        let opening = try #require(OpeningPrompt("hello", agentID: pi.agent.id))
        await h.server.sendOpeningPrompt(opening, sessionID: pi.sessionID)
        #expect(try store(h).checkpoint(for: pi.agent.id)?.pending.first?.entry.text == "hello")
        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("boot").path, contents: nil)
        _ = try await pi.snapshot { !$0.running && $0.messages.count == 5 }
        #expect(pi.stdin("prompt").count == 1, "The current opening prompt is not an old recovery checkpoint")
    }

    @Test func failedStartsDoNotConsumeRecoveryOrOverwriteItsCheckpoint() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        h.stop(keepFiles: true)
        let saved = try #require(try store(h).checkpoint(for: pi.agent.id))
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted, env: ["STUB_PI_STARTUP_EXIT": "1"])
        try await eventually("the failed start") { await restarted.server.sessionInfo(sessionID: restored.sessionID)?.isAlive == false }
        #expect(try store(restarted).checkpoint(for: pi.agent.id) == saved)
        #expect(restored.stdin("prompt").isEmpty)
    }

    @Test func persistenceFailureRejectsANewSendInsteadOfLosingIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        // A file where the checkpoint directory must be makes atomic persistence impossible.
        try Data().write(to: h.dir.appendingPathComponent("agent-recovery"))
        #expect(try await pi.send("do not lose this", from: idle).failureCode == "persist_failed")
        #expect(pi.stdin("prompt").isEmpty)
    }

    @Test(arguments: [false, true])
    func uncertainInputsAreReconciledRatherThanBlindlyReplayed(expanded: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        let text = expanded ? "/skill deployment" : "user text"
        let historyText = expanded ? "Expanded skill instructions for deployment" : text
        let history: [[String: Any]] = [["role": "user", "timestamp": 1000,
                                       "content": [["type": "text", "text": historyText]]]]
        let messages = h.dir.appendingPathComponent("messages.json")
        try JSONSerialization.data(withJSONObject: history).write(to: messages)
        let input = RPCThreadState.QueueItem(entry: NativeQueuedMessage(id: UUID(), text: text, sentAt: 1000), images: [])
        try store(h).save(.init(sessionID: "stub-session", active: false, items: [], pending: [input], paused: false,
                               mode: .oneAtATime), for: pi.agent.id)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted, env: ["STUB_PI_MESSAGES_FILE": messages.path])
        let paused = try await restored.snapshot { $0.queue?.paused == true }
        #expect(paused.queue?.items.first?.text == text, "Uncertain user input remains unchanged, never wrapped in host instructions")
        #expect(restored.stdin("prompt").isEmpty && restored.stdin("resume_session").isEmpty)
    }

    @Test func repeatedCrashesDuringRecoveryHitTheDurableAttemptBound() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        h.stop(keepFiles: true)
        for attempt in 1...(AgentRecoveryStore.attemptLimit + 1) {
            let restarted = try ScratchServer(dir: h.dir)
            let restored = try await resume(pi, on: restarted,
                                            env: ["STUB_PI_RESUME_GATE": h.dir.appendingPathComponent("never").path])
            _ = try await restored.ready()
            if attempt <= AgentRecoveryStore.attemptLimit {
                _ = try await restored.waitForStdin("resume_session")
                let checkpoint = try #require(try store(restarted).checkpoint(for: pi.agent.id))
                #expect(checkpoint.attempts == attempt)
                #expect(checkpoint.active && checkpoint.pending.isEmpty, "Host recovery instructions must not become queued user inputs")
            } else {
                #expect(restored.stdin("prompt").isEmpty && restored.stdin("resume_session").isEmpty, "Repeated crashes cannot cause an unlimited recovery loop")
            }
            restarted.stop(keepFiles: true)
        }
    }

    @Test(arguments: [false, true])
    func restartReservationPrecedesPreparationAndStopCanCancelIt(stop: Bool) async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        try store(h).save(.init(sessionID: "stub-session", active: true, items: [], pending: [], paused: false,
                               mode: .oneAtATime), for: pi.agent.id)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted, env: ["STUB_PI_STARTUP_GATE": "restart-boot"])
        let gate = RestartPreparationGate()
        try await restarted.server.enqueue {
            restarted.server.rpcThread(forAgent: pi.agent.id)?.beforePrompt = { gate.pending = $0 }
        }
        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("restart-boot").path, contents: nil)
        try await eventually("restart preparation") { try await restarted.server.enqueue { gate.pending != nil } }
        let saved = try #require(try store(restarted).checkpoint(for: pi.agent.id))
        #expect(saved.operationID != nil && saved.token != nil && saved.fence != nil && saved.active)
        #expect(restored.stdin("resume_session").isEmpty && restored.stdin("prompt").isEmpty)
        if stop {
            let ready = try await restored.ready()
            #expect(try await restored.request(.abort(expectedSessionID: ready.piSessionID, generation: ready.generation,
                                                     operationID: UUID())).failureCode == nil)
        }
        try await restarted.server.enqueue { gate.pending?(); gate.pending = nil }
        if stop {
            #expect(restored.stdin("resume_session").isEmpty)
        } else {
            let sent = try await restored.waitForStdin("resume_session")
            #expect((sent["operationID"] as? String)?.lowercased() == saved.operationID?.uuidString.lowercased())
            #expect(sent["token"] as? String == saved.token)
        }
        #expect(restored.stdin("prompt").isEmpty)
    }

    @Test(arguments: ["unknown", "settled", "absent", "absent-new-runtime", "changed-fence", "legacy"])
    func restartOperationsReconcileBeforeAnyNewModelCall(outcome: String) async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        let id = UUID()
        let queued = RPCThreadState.QueueItem(entry: NativeQueuedMessage(id: UUID(), text: "actual queued input", sentAt: 1000), images: [])
        try store(h).save(.init(sessionID: "stub-session", active: true, items: [queued], pending: [], paused: false,
                               mode: .oneAtATime, attempts: 1, operationID: id, token: String(repeating: "a", count: 64),
                               fence: outcome == "legacy" ? nil : String(repeating: "b", count: 64)), for: pi.agent.id)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        var env: [String: String] = [:]
        if ["unknown", "settled"].contains(outcome) { env["STUB_PI_RESTART_RECEIPT_STATE"] = outcome }
        if outcome == "absent-new-runtime" { env["STUB_PI_RESTART_TOKEN"] = String(repeating: "c", count: 64) }
        if outcome == "changed-fence" { env["STUB_PI_RESTART_FENCE"] = String(repeating: "d", count: 64) }
        let restored = try await resume(pi, on: restarted, env: env)
        _ = try await restored.waitForStdin("get_recovery_operation")
        if ["unknown", "changed-fence", "legacy"].contains(outcome) {
            _ = try await restored.snapshot { $0.queue?.paused == true }
            #expect(restored.stdin("resume_session").isEmpty && restored.stdin("prompt").isEmpty)
        } else {
            if outcome.hasPrefix("absent") {
                let operation = try await restored.waitForStdin("resume_session")
                #expect((operation["operationID"] as? String)?.lowercased() == id.uuidString.lowercased())
                #expect(operation["token"] as? String == String(repeating: outcome == "absent-new-runtime" ? "c" : "a", count: 64))
            }
            #expect(try await restored.waitForStdin("prompt")["message"] as? String == "actual queued input")
            if outcome == "settled" { #expect(restored.stdin("resume_session").isEmpty) }
        }
    }

    @Test(arguments: [false, true])
    func stopOrNewInputFencesADelayedEngineRecoveryCheck(stop: Bool) async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        try store(h).save(.init(sessionID: "stub-session", active: true, items: [], pending: [], paused: false,
                               mode: .oneAtATime), for: pi.agent.id)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let gate = h.dir.appendingPathComponent("release-recovery")
        let restored = try await resume(pi, on: restarted, env: ["STUB_PI_RESTART_CHECK_GATE": gate.path])
        _ = try await restored.waitForStdin("get_restart_recovery")
        let ready = try await restored.ready()
        if stop {
            #expect(try await restored.request(.abort(expectedSessionID: ready.piSessionID, generation: ready.generation,
                                                     operationID: UUID())).failureCode == nil)
        } else {
            #expect(try await restored.send("new actual input", from: ready).failureCode == nil)
            #expect(try await restored.waitForStdin("prompt")["message"] as? String == "new actual input")
        }
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        _ = try await restored.snapshot { !$0.running }
        #expect(restored.stdin("resume_session").isEmpty, "Late recovery preflight cannot override newer user intent")
    }

    @Test(arguments: ["recovery_uncertain_tool", "recovery_completed"])
    func engineCheckpointsKeepUnsafeWorkPausedAndDrainAfterDurableCompletion(reason: String) async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        let queued = RPCThreadState.QueueItem(entry: NativeQueuedMessage(id: UUID(), text: "keep queued", sentAt: 1000), images: [])
        try store(h).save(.init(sessionID: "stub-session", active: true, items: [queued], pending: [], paused: false,
                               mode: .oneAtATime), for: pi.agent.id)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted, env: ["STUB_PI_RESTART_REFUSAL": reason])
        if reason == "recovery_completed" {
            #expect(try await restored.waitForStdin("prompt")["message"] as? String == "keep queued")
        } else {
            let paused = try await restored.snapshot { $0.queue?.paused == true }
            #expect(paused.queue?.items.first?.text == "keep queued")
            #expect(restored.stdin("prompt").isEmpty)
        }
        #expect(restored.stdin("resume_session").isEmpty)
    }

    @Test func stopSurvivesALateAgentStartAndAnUncleanRestart() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("late-start", from: try await pi.ready())
        _ = try await pi.waitForStdin("prompt")
        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("clear-gate").path, contents: nil)
        let snapshot = try await pi.snapshot()
        let stopping = Task { try await pi.request(.abort(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID())) }
        _ = try await pi.waitForStdin("clear_queue")
        #expect(try store(h).checkpoint(for: pi.agent.id)?.active != true)
        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("late-start").path, contents: nil)
        _ = try await pi.snapshot {
            $0.running && $0.provisional.contains {
                $0.role == "user" && !$0.entryID.hasPrefix("pending:") && $0.blocks.first?.text == "late-start"
            }
        }
        #expect(try store(h).checkpoint(for: pi.agent.id)?.active != true, "A late agent_start cannot undo Stop")
        let crashDirectory = try makeScratchDirectory("stoprace")
        try FileManager.default.copyItem(at: h.stateURL, to: crashDirectory.appendingPathComponent("state.json"))
        try FileManager.default.copyItem(at: h.dir.appendingPathComponent("agent-recovery"),
                                        to: crashDirectory.appendingPathComponent("agent-recovery"))
        h.stop(keepFiles: true)
        _ = try? await stopping.value
        let restarted = try ScratchServer(dir: crashDirectory)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        _ = try await restored.ready()
        #expect(restored.stdin("prompt").isEmpty)
    }

    @Test(arguments: [false, true])
    func degradedHistoryPreservesDeferredRecoveryUntilReconciliation(savedRecovery: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        let queued = RPCThreadState.QueueItem(entry: NativeQueuedMessage(id: UUID(), text: "old saved work", sentAt: 1000), images: [])
        let checkpoint = AgentRecoveryStore.Checkpoint(sessionID: "stub-session", active: false, items: [queued], pending: [],
                                                       paused: false, mode: .oneAtATime, attempts: 2)
        if savedRecovery { try store(h).save(checkpoint, for: pi.agent.id) }
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        restarted.server.setHiddenSlashCommands(["disabled"])
        let gate = restarted.dir.appendingPathComponent("history-ready")
        let restored = try await resume(pi, on: restarted, env: ["STUB_PI_HISTORY_FAILURE_GATE": gate.path])
        let degraded = try await restored.snapshot { $0.clips?.history == true }
        #expect(try await restored.send("/disabled", from: degraded).failureCode == "unsupported")
        #expect(try await restored.send("", from: degraded).failureCode == "invalid")
        if savedRecovery {
            #expect(try store(restarted).checkpoint(for: pi.agent.id) == checkpoint, "Rejected commands cannot reset attempts or discard the old queue")
        }
        let result = try await restored.send("new authorized input", from: degraded)
        if savedRecovery {
            #expect(result.failureCode == "native_starting")
            #expect(try store(restarted).checkpoint(for: pi.agent.id) == checkpoint)
            #expect(restored.stdin("prompt").isEmpty)
        } else {
            #expect(result.failureCode == nil, "No saved recovery: preserve ordinary degraded-history sends")
            _ = try await restored.waitForStdin("prompt")
        }
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        _ = try await restored.snapshot { $0.clips?.history != true }
        if savedRecovery {
            #expect(try await restored.waitForStdin("prompt")["message"] as? String == "old saved work")
            let idle = try await restored.snapshot { !$0.running && $0.queue?.items.isEmpty != false }
            #expect(try await restored.send("new authorized input", from: idle).failureCode == nil)
            #expect(try await restored.waitForStdin("prompt", count: 2)["message"] as? String == "new authorized input")
        }
    }

    @Test(arguments: [false, true])
    func stopAlsoCancelsRecoveryWhileHistoryIsUnavailable(reserved: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }
        _ = try await pi.send("old queued work", from: working)
        h.stop(keepFiles: true)
        if reserved {
            var saved = try #require(try store(h).checkpoint(for: pi.agent.id))
            saved.operationID = UUID()
            saved.token = String(repeating: "a", count: 64)
            saved.fence = String(repeating: "b", count: 64)
            try store(h).save(saved, for: pi.agent.id)
        }
        let deferred = try ScratchServer(dir: h.dir)
        let waiting = try await resume(pi, on: deferred, env: ["STUB_PI_HISTORY_FAILURE_GATE": h.dir.appendingPathComponent("never-ready").path])
        let degraded = try await waiting.snapshot { $0.clips?.history == true }
        _ = try await waiting.request(.abort(expectedSessionID: degraded.piSessionID, generation: degraded.generation, operationID: UUID()))
        let saved = try #require(try store(deferred).checkpoint(for: pi.agent.id))
        #expect(!saved.active && saved.paused && saved.items.first?.entry.text == "old queued work")
        #expect(saved.operationID == nil && saved.token == nil && saved.fence == nil)
        deferred.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        let idle = try await restored.ready()
        #expect(idle.queue?.paused == true && idle.queue?.items.first?.text == "old queued work")
        #expect(restored.stdin("prompt").isEmpty && restored.stdin("resume_session").isEmpty)
        #expect(restored.stdin("get_recovery_operation").isEmpty, "Stop discards the reservation, not just its active flag")
    }

    @Test func corruptCheckpointsAreQuarantinedWithoutBlockingNewAuthorizedWork() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running }
        h.stop(keepFiles: true)
        let directory = h.dir.appendingPathComponent("agent-recovery")
        let original = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let damaged = Data("{\"active\":true,\"unfinished_authorized_input\":\"preserve these bytes\"".utf8)
        try damaged.write(to: original)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        let idle = try await restored.ready()
        #expect(restored.stdin("prompt").isEmpty, "Unreadable recovery cannot authorize a continuation")
        let archived = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains(".corrupt-") })
        #expect(try Data(contentsOf: archived) == damaged)
        #expect(try await restored.send("new authorized work", from: idle).failureCode == nil)
        #expect(try await restored.waitForStdin("prompt")["message"] as? String == "new authorized work")
        #expect(try Data(contentsOf: archived) == damaged, "A new checkpoint must not overwrite the quarantined work")
    }

    @Test func aCheckpointForAnotherConversationNeverRuns() async throws {
        let h = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        h.stop(keepFiles: true)
        try store(h).save(.init(sessionID: "different-session", active: true, items: [], pending: [], paused: false,
                               mode: .oneAtATime), for: pi.agent.id)
        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        let restored = try await resume(pi, on: restarted)
        _ = try await restored.ready()
        #expect(restored.stdin("prompt").isEmpty)
        #expect(try store(restarted).checkpoint(for: pi.agent.id) == nil)
    }
}

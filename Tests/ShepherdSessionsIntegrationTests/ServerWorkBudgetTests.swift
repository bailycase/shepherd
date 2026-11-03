import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Server work budgets", .integrationTimeLimit)
struct ServerWorkBudgetTests {
    @Test func transcriptPagesReuseBothFilesAndNeverHoldTheOwnerQueue() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        let ready = try await t.ready()
        let file = t.dir.appendingPathComponent("child.jsonl")
        let lines = (0..<100).map { #"{"type":"message","id":"u\#($0)","message":{"role":"user","content":"step \#($0)","timestamp":10000}}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let held = DispatchSemaphore(value: 0), entered = Locked(false), result = Locked<NativeThreadResult?>(nil)
        defer { held.signal() }
        t.queue.sync {
            t.state.setSubagents([ChildRun(runID: "child", label: "child", state: "running", sessionFile: file.path)])
            t.state.beforeTranscriptRead = { entered.withValue { $0 = true }; held.wait() }
            t.state.handle(.subagentTranscript(expectedSessionID: ready.piSessionID, runID: "child")) { value in result.withValue { $0 = value } }
        }
        try await eventually("transcript builder gated") { entered.current }
        #expect(try await t.snapshot().piSessionID == ready.piSessionID)
        t.queue.sync { t.state.beforeTranscriptRead = nil }
        held.signal()
        try await eventually("transcript answered") { result.current != nil }
        guard case .transcript(let page) = result.current else { Issue.record("missing transcript"); return }
        #expect(page.earlierCount == 50)
        _ = await t.request(.subagentTranscript(expectedSessionID: ready.piSessionID, runID: "child", beforeEntryID: page.olderCursor))
        #expect(t.queue.sync { t.state.transcriptBuildCount } == 1)
        let sidecar = t.dir.appendingPathComponent(RPCThreadState.userMessagesFile)
        try #"{"text":"step 99","at":10000}"#.write(to: sidecar, atomically: true, encoding: .utf8)
        guard case .transcript(let attributed) = await t.request(.subagentTranscript(expectedSessionID: ready.piSessionID, runID: "child")) else { Issue.record("missing transcript"); return }
        #expect(attributed.messages.last?.origin == .user)
        #expect(t.queue.sync { t.state.transcriptBuildCount } == 2)
        // Same-length atomic replacement must invalidate independently of transcript bytes.
        try #"{"text":"step 98","at":10000}"#.write(to: sidecar, atomically: true, encoding: .utf8)
        guard case .transcript(let edited) = await t.request(.subagentTranscript(expectedSessionID: ready.piSessionID, runID: "child")) else { Issue.record("missing transcript"); return }
        #expect(edited.messages.last?.origin == nil && edited.messages.dropLast().last?.origin == .user)
        #expect(t.queue.sync { t.state.transcriptBuildCount } == 3)
        try FileManager.default.removeItem(at: sidecar)
        guard case .transcript(let removed) = await t.request(.subagentTranscript(expectedSessionID: ready.piSessionID, runID: "child")) else { Issue.record("missing transcript"); return }
        #expect(removed.messages.allSatisfy { $0.origin == nil })
        let rebound = DispatchSemaphore(value: 0), reading = Locked(false), stale = Locked<NativeThreadResult?>(nil)
        defer { rebound.signal() }
        t.queue.sync {
            t.state.beforeTranscriptRead = { reading.withValue { $0 = true }; rebound.wait() }
            t.state.handle(.subagentTranscript(expectedSessionID: ready.piSessionID, runID: "child")) { value in stale.withValue { $0 = value } }
        }
        try await eventually("transcript binding held") { reading.current }
        t.queue.sync { t.state.setSubagents([]) }
        rebound.signal()
        try await eventually("removed child rejected") { stale.current != nil }
        #expect(stale.current?.failureCode == "unknown_run")
    }

    @Test func historySuccessesCoalesceBehindTwoWorkers() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(0), completed = Locked(0)
        defer { held.signal(); held.signal() }
        let baseline = t.queue.sync { t.state.historyProjectionCount }
        t.queue.sync {
            t.state.beforeHistoryImages = {
                let n = entered.withValue { $0 += 1; return $0 }
                if n <= 2 { held.wait() }
            }
            for _ in 0..<12 {
                t.state.refreshMessages { _ in completed.withValue { $0 += 1 } }
            }
        }
        try await eventually("two history workers and superseded answers") { entered.current == 2 && completed.current == 9 }
        #expect(try await t.snapshot().messages.count == 2)
        #expect(t.queue.sync { t.state.historyProjectionCount - baseline } == 2)
        held.signal(); held.signal()
        try await eventually("every refresh completes once") { completed.current == 12 }
        #expect(t.queue.sync { t.state.historyProjectionCount - baseline } == 3)
        #expect(try await t.snapshot().messages.count == 2)
    }

    @Test func reconciliationRetriesItsImmutableBaselineWhenAHostRowArrives() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(false), done = Locked(false)
        defer { held.signal() }
        let baseline = t.queue.sync { t.state.historyReconciliationCount }
        t.queue.sync {
            t.state.beforeHistoryReconciliation = { entered.withValue { $0 = true }; held.wait() }
            t.state.refreshMessages { _ in done.withValue { $0 = true } }
        }
        try await eventually("reconciliation held against its baseline") { entered.current }
        let id = UUID()
        t.queue.sync {
            t.state.beforeHistoryReconciliation = nil
            t.state.commandNotices.append(.init(id: id, level: .info, text: "arrived during reconciliation", at: 1))
        }
        #expect(try await t.snapshot().messages.count == 2)
        held.signal()
        try await eventually("rebased reconciliation applied") { done.current }
        #expect(try await t.snapshot().messages.contains { $0.entryID == "n:\(id.uuidString)" })
        #expect(t.queue.sync { t.state.historyReconciliationCount - baseline } == 2)
    }

    @Test func bulkAndFollowingInputKeepTheirSerializedOrder() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(false), replies = Locked(0)
        defer { held.signal() }
        let image = ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: 600_000))
        t.queue.sync {
            t.session.beforeInputPreparation = { entered.withValue { $0 = true }; held.wait() }
            t.state.requestInput(prompt: "/session-name info first", images: [image], delivery: .followUp) { failure in
                #expect(failure == nil); replies.withValue { $0 += 1 }
            }
            t.state.requestInput(prompt: "/session-name info second", images: [], delivery: .steer) { failure in
                #expect(failure == nil); replies.withValue { $0 += 1 }
            }
        }
        try await eventually("first input held before serialization") { entered.current }
        #expect(t.queue.sync { t.state.waitingInputs.count } == 1)
        #expect(replies.current == 0)
        held.signal()
        try await eventually("both ordered inputs answered") { replies.current == 2 }
        let log = try String(contentsOf: t.dir.appendingPathComponent("inputs.jsonl"), encoding: .utf8)
        let prompts = try log.split(separator: "\n").compactMap { line -> String? in
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return value?["type"] as? String == "prompt" ? value?["message"] as? String : nil
        }
        #expect(prompts == ["/session-name info first", "/session-name info second"])
    }

    @Test(arguments: [false, true]) func stopBypassesBulkPreparationAndCancelsBeforeAnyPromptBytes(steer: Bool) async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "inputs.jsonl"])
        defer { t.stop() }
        let ready = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(false), result = Locked<NativeThreadResult?>(nil)
        let checkpoints = Locked(0)
        defer { held.signal() }
        let images = [2, 2, 1].map { ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: $0 * 1024 * 1024)) }
        if steer { try await t.feed(#"{"type":"agent_start"}"#) }
        t.queue.sync {
            t.state.onRecoveryChanged = { checkpoints.withValue { $0 += 1 }; return true }
            t.session.beforeInputPreparation = { entered.withValue { $0 = true }; held.wait() }
            t.state.handle(.send(expectedSessionID: ready.piSessionID, generation: ready.generation,
                                 operationID: UUID(), text: "must never reach pi", delivery: steer ? .steer : .followUp, images: images)) {
                value in result.withValue { $0 = value }
            }
        }
        try await eventually("bulk preparation gated") { entered.current }
        #expect(checkpoints.current > 0, "durable admission precedes preparation")
        #expect(try await t.snapshot().piSessionID == ready.piSessionID)
        let stopped = await withCheckedContinuation { continuation in
            t.queue.async { t.state.stop { continuation.resume(returning: $0) } }
        }
        #expect(try stopped.get().success, "abort must answer while preparation is held")
        if !steer { #expect(result.current?.failureCode == "send_cancelled", "Stop answers the unadmitted send without waiting for preparation") }
        held.signal()
        try await eventually("cancelled send answers") { result.current != nil }
        #expect(result.current?.failureCode == "send_cancelled")
        let log = try String(contentsOf: t.dir.appendingPathComponent("inputs.jsonl"), encoding: .utf8)
        #expect(!log.contains("must never reach pi"))
    }

    @Test func projectCancellationUsesTheSameAdmissionFenceDuringFramePreparation() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "inputs.jsonl"])
        defer { t.stop() }
        let ready = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(false), results = Locked<[NativeThreadResult]>([])
        defer { held.signal() }
        let image = ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: 600_000)), operation = UUID()
        t.queue.sync {
            t.session.beforeInputPreparation = { entered.withValue { $0 = true }; held.wait() }
            t.state.handle(.send(expectedSessionID: ready.piSessionID, generation: ready.generation,
                                 operationID: operation, text: "cancelled project input", delivery: .followUp, images: [image])) {
                value in results.withValue { $0.append(value) }
            }
        }
        try await eventually("project input preparing its frame") { entered.current }
        #expect(t.queue.sync { t.state.cancelExecutionPrompt(operation) })
        #expect(results.current.count == 1 && results.current.first?.failureCode == "send_cancelled")
        held.signal()
        try await eventually("cancelled preparation releases the lane") { t.queue.sync { !t.state.inputActive } }
        #expect(results.current.count == 1)
        let log = try String(contentsOf: t.dir.appendingPathComponent("inputs.jsonl"), encoding: .utf8)
        #expect(!log.contains("cancelled project input"))
    }

    @Test func sessionSwitchFencesPreparedBytesWithoutBlockingTheNewInputLane() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "inputs.jsonl"])
        defer { t.stop() }
        let ready = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(false), result = Locked<NativeThreadResult?>(nil)
        defer { held.signal() }
        let image = ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: 600_000))
        t.queue.sync {
            t.session.beforeInputPreparation = { entered.withValue { $0 = true }; held.wait() }
            t.state.requestInput(prompt: "old prepared input", images: [image], delivery: .followUp) { value in result.withValue { $0 = value } }
        }
        try await eventually("old generation preparing") { entered.current }
        let switched = await withCheckedContinuation { continuation in
            t.queue.async { t.session.request(.prompt(message: "resume-nonempty")) { continuation.resume(returning: $0) } }
        }
        #expect(try switched.get().success)
        t.queue.async { t.state.refreshState() }
        try await eventually("new generation serves") {
            guard let snapshot = await t.request(.snapshot()).snapshotValue else { return false }
            return snapshot.piSessionID != ready.piSessionID
        }
        let next: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(prompt: "/session-name info new generation", images: [], delivery: .followUp) { continuation.resume(returning: $0) }
            }
        }
        #expect(next == nil)
        held.signal()
        try await eventually("old prepared input rejected") { result.current != nil }
        #expect(result.current?.failureCode == "stale_session")
        #expect(t.queue.sync { !t.state.inputActive && !t.state.inputOutcomeUnknown })
        let log = try String(contentsOf: t.dir.appendingPathComponent("inputs.jsonl"), encoding: .utf8)
        #expect(!log.contains("old prepared input"))
    }

    @Test func stderrFloodYieldsAndItsFinalUnterminatedLinePrecedesExit() async throws {
        let h = try RPCSessionTests.Harness(command: ["python3", "-c", """
        import os, pathlib, time
        while not pathlib.Path('go').exists(): time.sleep(0.01)
        data = (b'diagnostic' + b'x' * 1013 + b'\\n') * 2048
        while data:
            n = os.write(2, data)
            data = data[n:]
        os.write(2, b'final diagnostic')
        """])
        defer { h.stop() }
        let sentinel = Locked<Int?>(nil)
        await h.onQueue {
            h.session.onStderr = { line in
                h.stderr.withValue { $0.append(line) }
                if h.stderr.current.count == 1 {
                    h.queue.async { sentinel.withValue { $0 = h.stderr.current.count } }
                }
            }
        }
        try Data().write(to: h.dir.appendingPathComponent("go"))
        try await eventually("stderr exits with final diagnostics") { h.exit.current.done }
        #expect(sentinel.current != nil && sentinel.current! < 2048)
        #expect(h.stderr.current.count == 2049)
        #expect(h.stderr.current.last == "final diagnostic")
        #expect(await h.onQueue { h.session.largestStderrTurn } <= RPCSession.stderrBudgetPerTurn)
    }

    @Test func recoveryAgentTraversalsFollowStateVersionsNotCheckpoints() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let a = try await PiAgent.launch(on: h), b = try await PiAgent.launch(on: h)
        _ = try await a.ready(); _ = try await b.ready()
        try await h.server.enqueue {
            let thread = h.server.rpcThread(forAgent: a.agent.id)!
            #expect(thread.onRecoveryChanged?() == true)
            let before = h.server.recoveryAgentIndexBuildCount
            for _ in 0..<100 { #expect(thread.onRecoveryChanged?() == true) }
            #expect(h.server.recoveryAgentIndexBuildCount == before)
            try h.server.mutateState { $0.agents.reverse() }
            #expect(thread.onRecoveryChanged?() == true)
            let rebuilt = h.server.recoveryAgentIndexBuildCount
            #expect(rebuilt == before + 1)
            for _ in 0..<100 { #expect(thread.onRecoveryChanged?() == true) }
            #expect(h.server.recoveryAgentIndexBuildCount == rebuilt)
        }
    }
}

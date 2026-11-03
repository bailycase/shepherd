import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Native boundary preparation fences", .integrationTimeLimit)
struct NativeBoundaryPreparationTests {
    @Test(arguments: [false, true], ["expiry", "stop", "switch"])
    func pendingPreparationCannotOutliveItsBoundaryOrSession(beforePrompt: Bool, end: String) async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "boundary-inputs.jsonl"])
        defer { t.stop() }
        let ready = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(false), workerFinished = Locked(false)
        let resume = Locked<(() -> Void)?>(nil), completed = Locked(0), failures = Locked<[String]>([])
        let checkpoints = Locked(0), beforePromptCalls = Locked(0)
        defer { held.signal() }
        let operation = UUID(), text = "boundary payload must not reach pi"
        let image = ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: 600_000))
        if !beforePrompt { try await t.feed(#"{"type":"agent_start"}"#) }
        t.queue.sync {
            t.state.restoringRecovery = false
            t.state.onRecoveryChanged = { checkpoints.withValue { $0 += 1 }; return true }
            t.state.beforePrompt = { continuation in
                beforePromptCalls.withValue { $0 += 1 }
                resume.withValue { $0 = continuation }
                entered.withValue { $0 = true }
            }
            t.session.beforeInputPreparation = { entered.withValue { $0 = true }; held.wait() }
            t.session.afterInputPreparation = { workerFinished.withValue { $0 = true } }
            let deadline = Date().timeIntervalSince1970 * 1000 + (end == "expiry" ? 2_000 : 10_000)
            if beforePrompt {
                // The bounded dispatch API also fences a pending capture/recovery continuation.
                // Native steering itself must continue to skip beforePrompt (the other case).
                t.state.dispatch(id: operation, text: text, images: [image], parts: nil, items: [], expiresAt: deadline) { result in
                    if let code = result.failureCode { failures.withValue { $0.append(code) } }
                    completed.withValue { $0 += 1 }
                }
            } else {
                t.state.items = [.init(entry: .init(id: operation, text: text, sentAt: 1), images: [image])]
                t.state.deliverAtBoundary(expiresAt: deadline) { completed.withValue { $0 += 1 } }
            }
        }
        try await eventually("preparation held before admission") { entered.current }
        #expect(checkpoints.current > 0)
        #expect(beforePromptCalls.current == (beforePrompt ? 1 : 0), "boundary steering starts no new Changes capture")
        if end == "stop" {
            let stopped = await withCheckedContinuation { continuation in
                t.queue.async { t.state.stop { continuation.resume(returning: $0) } }
            }
            #expect(try stopped.get().success)
        } else if end == "switch" {
            let switched = await withCheckedContinuation { continuation in
                t.queue.async { t.session.request(.prompt(message: "resume-nonempty")) { continuation.resume(returning: $0) } }
            }
            #expect(try switched.get().success)
            t.queue.async { t.state.refreshState() }
            try await eventually("new generation serves") {
                guard let snapshot = await t.request(.snapshot()).snapshotValue else { return false }
                return snapshot.generation != ready.generation
            }
        }
        try await eventually("boundary or pending capture answered before its worker resumes") { completed.current == 1 }
        if beforePrompt {
            #expect(failures.current == [end == "expiry" ? "boundary_expired" : "send_cancelled"])
        } else if end != "switch" {
            t.queue.sync {
                #expect(t.state.paused && t.state.items.map(\.entry.id) == [operation])
                #expect(t.state.items.first?.images == [image])
                if end == "expiry" { #expect(t.state.queueNotice?.contains("timed out") == true) }
            }
        }
        if beforePrompt {
            t.queue.sync { resume.current?() }
        } else {
            held.signal()
            try await eventually("late frame worker returns") { workerFinished.current }
        }
        let fence = await withCheckedContinuation { continuation in
            t.queue.async { t.session.request(.getState) { continuation.resume(returning: $0) } }
        }
        #expect(try fence.get().success)
        #expect(completed.current == 1)
        let log = try String(contentsOf: t.dir.appendingPathComponent("boundary-inputs.jsonl"), encoding: .utf8)
        #expect(!log.contains(text), "no bytes from an expired/cancelled preparation reach pi")
    }

    @Test func anExpiredCaptureContinuationDoesNotStrandLaterSerializedInputs() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "boundary-inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        let held = DispatchSemaphore(value: 0), entered = Locked(false), expired = Locked<[NativeThreadResult]>([])
        let resume = Locked<(() -> Void)?>(nil), accepted = Locked(0)
        defer { held.signal() }
        let image = ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: 600_000))
        t.queue.sync {
            t.state.beforePrompt = { continuation in resume.withValue { $0 = continuation } }
            t.state.dispatch(id: UUID(), text: "expired capture", images: [], parts: nil, items: [],
                             expiresAt: Date().timeIntervalSince1970 * 1000 + 2_000) { result in expired.withValue { $0.append(result) } }
            t.session.beforeInputPreparation = { entered.withValue { $0 = true }; held.wait() }
            t.state.requestInput(prompt: "/session-name info first", images: [image], delivery: .steer) { failure in
                #expect(failure == nil); accepted.withValue { $0 += 1 }
            }
            resume.current?() // This bounded continuation now waits behind the first frame.
            t.state.requestInput(prompt: "/session-name info third", images: [], delivery: .steer) { failure in
                #expect(failure == nil); accepted.withValue { $0 += 1 }
            }
            #expect(t.state.waitingInputs.count == 2)
        }
        try await eventually("first frame held and middle continuation expired") { entered.current && expired.current.count == 1 }
        #expect(expired.current.first?.failureCode == "boundary_expired")
        held.signal()
        try await eventually("first and third inputs complete despite the expired middle input") { accepted.current == 2 }
        #expect(expired.current.count == 1)
        #expect(t.queue.sync { !t.state.inputActive && t.state.waitingInputs.isEmpty })
        let log = try String(contentsOf: t.dir.appendingPathComponent("boundary-inputs.jsonl"), encoding: .utf8)
        #expect(!log.contains("expired capture"))
        let prompts = try log.split(separator: "\n").compactMap { line -> String? in
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return value?["type"] as? String == "prompt" ? value?["message"] as? String : nil
        }
        #expect(prompts == ["/session-name info first", "/session-name info third"])
    }

    @Test func aFailedRestoreCheckpointKeepsBoundaryOwnedAndUnownedInput() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "boundary-inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        let boundaryID = UUID(), ownedID = UUID(), done = Locked<[Bool]>([])
        let image = ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: 600_000))
        t.queue.sync {
            t.state.restoringRecovery = false
            let boundary = RPCThreadState.QueueItem(entry: .init(id: boundaryID, text: "boundary batch", sentAt: 1), images: [image])
            let owned = RPCThreadState.QueueItem(entry: .init(id: ownedID, text: "owned steer", sentAt: 2, state: .steering), images: [image])
            t.state.items = [owned]
            t.state.dispatches = [.init(id: boundaryID, text: "boundary batch", images: [image], parts: nil,
                                        items: [boundary], expectsMessage: true, delivery: .steer)]
            t.state.onPrepareRecovery = { _, _, _, completion in completion(false) }
            t.state.restorePiQueue(steering: ["boundary batch", "owned steer", "extension steer"], followUp: ["extension followup"], origin: .init(t.state)) { saved in
                done.withValue { $0.append(saved) }
            }
            #expect(t.state.paused && t.state.dispatches.isEmpty)
            #expect(t.state.items.map(\.entry.text) == ["boundary batch", "owned steer", "extension steer", "extension followup"])
            #expect(t.state.items.prefix(2).map(\.entry.id) == [boundaryID, ownedID])
            #expect(t.state.items.prefix(2).allSatisfy { $0.images == [image] && $0.entry.state == .queued })
        }
        #expect(done.current == [false])
    }

    @Test func queuedSteeringKeepsAuthorizationThroughFramePreparation() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "boundary-inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(#"{"type":"agent_start"}"#)
        let held = DispatchSemaphore(value: 0), entered = Locked(false), finished = Locked(false), authorized = Locked(true)
        defer { held.signal() }
        let image = ThreadImagesTests.nativeImage(ThreadImagesTests.png(bytes: 600_000)), id = UUID()
        t.queue.sync {
            t.state.restoringRecovery = false
            t.session.beforeInputPreparation = { entered.withValue { $0 = true }; held.wait() }
            t.session.afterInputPreparation = { finished.withValue { $0 = true } }
            t.state.items = [.init(entry: .init(id: id, text: "revoked queued steer", sentAt: 1), images: [image])]
            t.state.perform(.steer(ids: [id]), operationID: UUID(), authorization: { authorized.current }) { _ in }
        }
        try await eventually("queued steer frame held") { entered.current }
        authorized.withValue { $0 = false }
        held.signal()
        try await eventually("revoked frame released and input lane finished") { finished.current && t.queue.sync { !t.state.inputActive } }
        let log = try String(contentsOf: t.dir.appendingPathComponent("boundary-inputs.jsonl"), encoding: .utf8)
        #expect(!log.contains("revoked queued steer"))
        #expect(t.queue.sync { t.state.items.first?.entry.state == .queued })
    }

    @Test func cancelledCaptureCannotBorrowANewerContinuationWithTheSameID() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "boundary-inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        let continuations = Locked<[() -> Void]>([]), old = Locked(0), newer = Locked(0)
        let id = UUID()
        t.queue.sync {
            t.state.beforePrompt = { next in continuations.withValue { $0.append(next) } }
            t.state.dispatch(id: id, text: "cancelled old capture", images: [], parts: nil, items: []) { _ in old.withValue { $0 += 1 } }
            t.state.cancelPreparingPrompts()
            t.state.dispatch(id: id, text: "slow newer capture", images: [], parts: nil, items: []) { _ in newer.withValue { $0 += 1 } }
            #expect(continuations.current.count == 2 && old.current == 1)
            continuations.current[0]()
            #expect(newer.current == 0 && t.state.preparingPrompts.count == 1)
            continuations.current[1]()
        }
        try await eventually("new capture alone completes") { newer.current == 1 }
        let log = try String(contentsOf: t.dir.appendingPathComponent("boundary-inputs.jsonl"), encoding: .utf8)
        #expect(!log.contains("cancelled old capture") && log.contains("slow newer capture"))
        #expect(old.current == 1)
    }

    @Test func anAdmittedBoundaryTimeoutKeepsItsUnknownOutcomeInsteadOfRequeueing() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "boundary-inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(#"{"type":"agent_start"}"#)
        let id = UUID(), completed = Locked(0)
        t.queue.sync {
            t.state.restoringRecovery = false
            t.state.items = [.init(entry: .init(id: id, text: "hang", sentAt: 1), images: [])]
            t.state.deliverAtBoundary(expiresAt: Date().timeIntervalSince1970 * 1000 + 1_000) { completed.withValue { $0 += 1 } }
        }
        try await eventually("admitted boundary reaches its response deadline") { completed.current == 1 }
        t.queue.sync {
            #expect(t.state.inputOutcomeUnknown)
            #expect(t.state.items.isEmpty, "a possibly delivered boundary must never be put back for automatic retry")
            #expect(t.state.dispatches.count == 1 && t.state.dispatches.first?.id == id)
            #expect(t.state.dispatches.first?.delivery == .steer)
            #expect(t.state.preparingPrompts.isEmpty)
        }
        let log = try String(contentsOf: t.dir.appendingPathComponent("boundary-inputs.jsonl"), encoding: .utf8)
        let prompts = try log.split(separator: "\n").filter {
            (try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String == "prompt"
        }
        #expect(prompts.count == 1 && completed.current == 1)
    }

    @Test func lateBoundaryConfirmationReconcilesSteeringBeforeRetiringOwnership() async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "boundary-inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        let id = UUID(), retired = Locked<[UUID]>([])
        t.queue.sync {
            var dispatch = RPCThreadState.Dispatch(id: id, text: "input-handler-consumed", parts: nil, items: [], expectsMessage: true, delivery: .steer)
            dispatch.responded = true
            t.state.dispatches.append(dispatch)
            t.state.paused = true
            t.state.onUnconsumedDispatchRetired = { value in retired.withValue { $0.append(value) } }
            t.state.confirmDispatch(id)
        }
        try await eventually("late boundary ownership reconciled") { retired.current == [id] }
        let log = try String(contentsOf: t.dir.appendingPathComponent("boundary-inputs.jsonl"), encoding: .utf8)
        #expect(log.contains("clear_queue"), "idle is not proof that pi consumed a boundary batch")
        #expect(t.queue.sync { t.state.dispatches.isEmpty })
    }
}

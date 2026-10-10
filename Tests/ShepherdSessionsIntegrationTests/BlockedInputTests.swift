import CryptoKit
import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Blocked model input", .integrationTimeLimit)
struct BlockedInputTests {
    @Test(arguments: [NativeThreadDelivery.followUp, .steer])
    func aBlockedInputFailsWithoutLeavingAPendingMessage(delivery: NativeThreadDelivery) async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        let s = try await t.ready()
        if delivery == .steer { try await t.feed(#"{"type":"agent_start"}"#) }
        let id = UUID()
        let result = await t.request(.send(expectedSessionID: s.piSessionID, generation: s.generation,
                                          operationID: id, text: "blocked-model", delivery: delivery,
                                          images: [NativeImage(mimeType: "image/png", data: Data([1, 2, 3]))]))
        guard case .failure(let code, let message) = result else { Issue.record("Expected rejection, got \(result)"); return }
        #expect(code == "model_unavailable")
        #expect(message.contains("CLIProxyAPI / saved-model"))
        #expect(message.contains("Your message wasn't sent"))
        let after = try await t.snapshot()
        #expect(after.queue?.items.isEmpty == true)
        #expect(!after.provisional.contains { $0.entryID == "pending:\(id.uuidString)" })
        #expect(after.widgets?.isEmpty == true, "the internal payload never renders as a widget")
        #expect(t.queue.sync { t.state.inputPrompts.isEmpty && t.state.inputFailures.isEmpty })
    }

    @Test func identicalConcurrentInputsKeepSeparatePreflightResults() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let results: [NativeThreadResult?] = await withCheckedContinuation { continuation in
            t.queue.async {
                var results: [NativeThreadResult?] = []
                let complete: (NativeThreadResult?) -> Void = {
                    results.append($0)
                    if results.count == 2 { continuation.resume(returning: results) }
                }
                t.state.requestInput(id: UUID(), prompt: "blocked-model-once", images: [], delivery: .followUp, completion: complete)
                t.state.requestInput(id: UUID(), prompt: "blocked-model-once", images: [], delivery: .followUp, completion: complete)
                #expect(t.state.inputPrompts.count == 1 && t.state.waitingInputs.count == 1)
            }
        }
        #expect(results.count == 2 && results[0] != nil && results[1] == nil,
                "one blocked input must not reject another identical input consumed by an extension")
        #expect(t.queue.sync { t.state.inputPrompts.isEmpty && t.state.waitingInputs.isEmpty })
    }

    @Test func aPreflightTimeoutFencesLaterInputsWithoutAnAnswer() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let failure: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(id: UUID(), prompt: "hang", images: [], delivery: .followUp, timeout: 1) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(failure == RPCThreadState.dispatchFailure(.failure(.timeout)))
        let next: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(id: UUID(), prompt: "must not send", images: [], delivery: .followUp) {
                    continuation.resume(returning: $0)
                }
            }
        }
        guard case .failure(let code, _) = next else { Issue.record("Expected fenced input, got \(String(describing: next))"); return }
        #expect(code == "input_pending")
        #expect(t.queue.sync { t.state.inputPrompts.isEmpty && t.state.inputFailures.isEmpty && t.state.waitingInputs.isEmpty })
    }

    @Test func aSendWaitsForPreflightCompactionPastTheOldThirtySecondDeadline() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        let s = try await t.ready()
        let id = UUID()
        let received = Locked<NativeThreadResult?>(nil)
        t.queue.async {
            t.state.handle(.send(expectedSessionID: s.piSessionID, generation: s.generation,
                                 operationID: id, text: "preflight-compact", delivery: .followUp, images: nil)) { result in
                received.withValue { $0 = result }
            }
        }
        try await eventually("the send's preflight compaction to start") {
            try await t.snapshot().context?.compacting != nil
        }
        // An unanswered RPC gives a deadline checkpoint, not a sleep waiting for work to finish.
        let checkpoint = await withCheckedContinuation { continuation in
            t.queue.async {
                t.session.request(.prompt(message: "hang"), timeout: 31) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(checkpoint == .failure(.timeout))
        #expect(received.current == nil, "compaction must not become an uncertain send at 30 seconds")
        try Data().write(to: t.dir.appendingPathComponent("preflight-go"))
        try Data().write(to: t.dir.appendingPathComponent("preflight-reply"))
        try await eventually("the compacted send to be accepted") { received.current != nil }
        #expect(received.current == .accepted(operationID: id))
    }

    @Test(arguments: [false, true])
    func aLatePromptResponseAfterCompactionUnlocksNewInputsWithoutResending(refused: Bool) async throws {
        let t = try ThreadEventTests.Thread(env: ["STUB_PI_LOG": "inputs.jsonl"])
        defer { t.stop() }
        _ = try await t.ready()
        let prompt = refused ? "preflight-compact-refuse" : "preflight-compact"
        let completions = Locked(0)
        let failure: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(id: UUID(), prompt: prompt, images: [], delivery: .followUp, timeout: 1) {
                    completions.withValue { $0 += 1 }
                    continuation.resume(returning: $0)
                }
            }
        }
        guard case .failure(let code, _) = failure else { Issue.record("Expected uncertain send"); return }
        #expect(code == "outcome_unknown")
        #expect(try await t.snapshot().context?.compacting != nil)

        // Neither another request's answer nor compaction_end resolves this prompt's preflight.
        let state = await withCheckedContinuation { continuation in
            t.queue.async { t.session.request(.getState) { continuation.resume(returning: $0) } }
        }
        #expect(try state.get().success)
        try Data().write(to: t.dir.appendingPathComponent("preflight-go"))
        try await eventually("compaction to finish before the prompt answers") {
            try await t.snapshot().context?.compacting == nil
        }
        let fenced: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(id: UUID(), prompt: "must not send", images: [], delivery: .followUp) {
                    continuation.resume(returning: $0)
                }
            }
        }
        guard case .failure(let code, _) = fenced else { Issue.record("Expected fenced input"); return }
        #expect(code == "input_pending")

        try Data().write(to: t.dir.appendingPathComponent("preflight-reply"))
        try await eventually("the matching late response to unlock sending") {
            t.queue.sync { !t.state.inputOutcomeUnknown }
        }
        let next: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(id: UUID(), prompt: "/session-name info next input", images: [], delivery: .followUp) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(next == nil)
        #expect(completions.current == 1, "the timed-out operation must not complete again")
        let log = try String(contentsOf: t.dir.appendingPathComponent("inputs.jsonl"), encoding: .utf8)
        let prompts = try log.split(separator: "\n").compactMap { line -> String? in
            let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return record?["type"] as? String == "prompt" ? record?["message"] as? String : nil
        }
        #expect(prompts == [prompt, "/session-name info next input"], "no timed-out or fenced input is retried")
    }

    @Test func stopDuringSteerRestorationKeepsEveryUndeliveredMessage() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await withCheckedContinuation { continuation in
            t.queue.async {
                let first = UUID(), second = UUID()
                t.state.items = [first, second].map { id in
                    RPCThreadState.QueueItem(entry: NativeQueuedMessage(id: id, text: id.uuidString, sentAt: 1, state: .steering), images: [])
                }
                t.state.inputActive = true
                t.state.restorePiQueue(steering: [first.uuidString, second.uuidString, "extension steer"], followUp: ["extension follow-up"])
                #expect(t.state.waitingInputs.count == 4)
                t.state.stop { _ in
                    t.state.settled()
                    #expect(t.state.items.map(\.entry.text).sorted() == [first.uuidString, second.uuidString, "extension steer", "extension follow-up"].sorted())
                    #expect(t.state.items.allSatisfy { $0.entry.state == .queued })
                    #expect(t.state.paused && t.state.waitingInputs.isEmpty)
                    continuation.resume()
                }
            }
        }
    }

    @Test func stopCancelsAnInputThatHasNotReachedPi() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let result: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.inputActive = true
                t.state.requestInput(id: UUID(), prompt: "blocked-model", images: [], delivery: .steer) {
                    continuation.resume(returning: $0)
                }
                #expect(t.state.waitingInputs.count == 1 && t.state.inputPrompts.isEmpty)
                t.state.stop { _ in }
            }
        }
        guard case .failure(let code, _) = result else { Issue.record("Expected cancelled input"); return }
        #expect(code == "send_cancelled")
        #expect(t.queue.sync { t.state.waitingInputs.isEmpty && t.state.inputPrompts.isEmpty })
    }

    @Test func onlyAMatchingHandledInputIsRejectedAndTheRecordExpiresWithItsResponse() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let text = "private input\nUnicode: café"
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
            "version": 1, "promptSHA256": digest, "modelId": "saved-model"
        ]), as: UTF8.self)
        t.queue.sync {
            let blocked = UUID(), other = UUID(), started = UUID()
            t.state.beginInput(blocked, prompt: text)
            t.state.beginInput(started, prompt: text)
            t.state.beginInput(other, prompt: "an unrelated consumed command")
            t.state.recordBlockedInput("{not JSON}")
            t.state.recordBlockedInput(payload.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"))
            #expect(t.state.inputFailures.isEmpty)
            t.state.recordBlockedInput(payload)
            let handled: Result<RPCResponse, RPCError> = .success(RPCResponse(command: "prompt", success: true,
                                                                             data: .object(["disposition": .string("handled")])))
            #expect(t.state.finishInput(other, result: handled) == nil)
            #expect(t.state.finishInput(started, result: .success(RPCResponse(command: "prompt", success: true,
                data: .object(["disposition": .string("started")])))) == nil)
            #expect(t.state.finishInput(blocked, result: handled) != nil)
            #expect(t.state.inputPrompts.isEmpty && t.state.inputFailures.isEmpty)
            t.state.recordBlockedInput(payload)
            t.state.beginInput(blocked, prompt: text)
            #expect(t.state.finishInput(blocked, result: handled) == nil, "late messages cannot poison the next send")
            t.state.beginInput(blocked, prompt: text)
            t.state.recordBlockedInput(payload)
            let timeout = t.state.finishInput(blocked, result: .failure(.timeout))
            #expect(timeout == RPCThreadState.dispatchFailure(.failure(.timeout)), "uncertain delivery never becomes retryable")
            #expect(t.state.inputPrompts.isEmpty && t.state.inputFailures.isEmpty)
        }
    }
}

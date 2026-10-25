import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Input preflights", .integrationTimeLimit)
struct BlockedInputTests {
    @Test func aPreflightTimeoutFencesLaterInputsWithoutAnAnswer() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let failure: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(prompt: "hang", images: [], delivery: .followUp, timeout: 1) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(failure == RPCThreadState.dispatchFailure(.failure(.timeout)))
        let next: NativeThreadResult? = await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.requestInput(prompt: "must not send", images: [], delivery: .followUp) {
                    continuation.resume(returning: $0)
                }
            }
        }
        guard case .failure(let code, _) = next else { Issue.record("Expected fenced input, got \(String(describing: next))"); return }
        #expect(code == "input_pending")
        #expect(t.queue.sync { t.state.waitingInputs.isEmpty })
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
                t.state.requestInput(prompt: prompt, images: [], delivery: .followUp, timeout: 1) {
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
                t.state.requestInput(prompt: "must not send", images: [], delivery: .followUp) {
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
                t.state.requestInput(prompt: "/session-name info next input", images: [], delivery: .followUp) {
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
                t.state.requestInput(prompt: "must not send", images: [], delivery: .steer) {
                    continuation.resume(returning: $0)
                }
                #expect(t.state.waitingInputs.count == 1)
                t.state.stop { _ in }
            }
        }
        guard case .failure(let code, _) = result else { Issue.record("Expected cancelled input"); return }
        #expect(code == "send_cancelled")
        #expect(t.queue.sync { t.state.waitingInputs.isEmpty })
    }


}

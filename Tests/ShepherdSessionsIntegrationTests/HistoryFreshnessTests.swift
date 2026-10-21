import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("History hydration freshness", .integrationTimeLimit)
struct HistoryFreshnessTests {
    private func fixture() async throws -> (ScratchServer, PiAgent, NativeThreadSnapshot) {
        let h = try ScratchServer.fresh()
        do {
            let file = h.dir.appendingPathComponent("history.json")
            let history: [[String: Any]] = [
                ["role": "user", "content": [["type": "text", "text": "look"], ["type": "image", "data": ThreadImagesTests.png(side: 16).base64EncodedString(), "mimeType": "image/png"]], "timestamp": 1_733_234_000_000],
                ["role": "assistant", "content": [["type": "text", "text": "seen"]], "stopReason": "stop", "timestamp": 1_733_234_000_001],
            ]
            try JSONSerialization.data(withJSONObject: history).write(to: file)
            let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": file.path])
            _ = try await pi.send("tools:2 original", from: try await pi.ready())
            let running = try await pi.snapshot("first tool running") { $0.running && $0.provisional.contains { $0.toolCallID != nil && $0.status == "running" } }
            return (h, pi, running)
        } catch { h.stop(); throw error }
    }

    @Test(arguments: [false, true]) func twoIdenticalSteersStayDistinctAcrossTheGatedImageAnswer(reconnect: Bool) async throws {
        let (h, pi, running) = try await fixture()
        defer { h.stop() }
        let client = RemoteHostClient()
        defer { client.disconnect() }
        var endpoint: (port: UInt16, token: String)?
        if reconnect {
            let tokenURL = h.dir.appendingPathComponent("viewer-token")
            let port = try h.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint = (port, token)
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "review-viewer")
        }
        let held = DispatchSemaphore(value: 0), entered = Locked(false), finished = Locked(false)
        defer { held.signal() }
        try await h.server.enqueue {
            let thread = h.server.rpcThread(forAgent: pi.agent.id)!
            thread.beforeHistoryImages = { entered.withValue { $0 = true }; held.wait() }
            thread.refreshMessages { _ in finished.withValue { $0 = true } }
        }
        try await eventually("old image answer gated") { entered.current }
        let ops = [UUID(), UUID()], text = "tools:1 identical steering words"
        for op in ops {
            #expect(try await pi.send(text, delivery: .steer, operationID: op, from: running) == .accepted(operationID: op))
        }
        pi.finishTool(1)
        _ = try await pi.snapshot("first identical steer consumed") { ($0.messages + $0.provisional).contains { $0.operationID == ops[0] && $0.role == "user" && $0.status == nil } }
        pi.finishTool(2)
        let before = try await pi.snapshot("second identical steer consumed") { ($0.messages + $0.provisional).contains { $0.operationID == ops[1] && $0.role == "user" && $0.status == nil } }
        let expected = (before.messages + before.provisional).filter { $0.role == "user" && ops.map(Optional.some).contains($0.operationID) }
        #expect(expected.count == 2 && Set(expected.map(\.entryID)).count == 2)
        if let endpoint {
            client.disconnect()
            _ = try await client.connect(host: "127.0.0.1", port: endpoint.port, token: endpoint.token, clientName: "review-viewer-reconnected")
            let reconnected = try #require(try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue)
            let visible = (reconnected.messages + reconnected.provisional).filter { ops.map(Optional.some).contains($0.operationID) }
            #expect(visible.map(\.entryID) == expected.map(\.entryID))
            #expect(reconnected.piSessionID == before.piSessionID && reconnected.generation == before.generation)
        }
        held.signal()
        try await eventually("old image answer applied") { finished.current }
        let after = try #require(try await pi.request(.snapshot()).snapshotValue)
        let shown = (after.messages + after.provisional).filter { $0.role == "user" && ops.map(Optional.some).contains($0.operationID) }
        #expect(shown.map(\.entryID) == expected.map(\.entryID))
        #expect(shown.map(\.operationID) == ops.map(Optional.some))
        #expect(shown.allSatisfy { $0.blocks.first?.text == text })
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.beforeHistoryImages = nil }
        pi.finishTool(3)
        let settled = try await pi.snapshot("both identical steers canonical") { snapshot in !snapshot.running && ops.allSatisfy { op in snapshot.messages.contains { $0.operationID == op } } }
        let saved = settled.messages.filter { $0.role == "user" && ops.map(Optional.some).contains($0.operationID) }
        #expect(saved.map(\.entryID) == expected.map(\.entryID))
        #expect(pi.stdin("prompt").filter { $0["message"] as? String == text }.count == 2)
    }

    private func idleImageFixture() async throws -> (ScratchServer, PiAgent, NativeThreadSnapshot, URL) {
        let h = try ScratchServer.fresh()
        do {
            let file = h.dir.appendingPathComponent("history.json"), gate = h.dir.appendingPathComponent("history-gate")
            let history: [[String: Any]] = [
                ["role": "user", "content": [["type": "text", "text": "look"], ["type": "image", "data": ThreadImagesTests.png(side: 16).base64EncodedString(), "mimeType": "image/png"]], "timestamp": 1_733_234_000_000],
                ["role": "assistant", "content": [["type": "text", "text": "seen"]], "stopReason": "stop", "timestamp": 1_733_234_000_001],
            ]
            try JSONSerialization.data(withJSONObject: history).write(to: file)
            try Data().write(to: gate)
            let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": file.path, "STUB_PI_HISTORY_GATE": gate.path])
            return (h, pi, try await pi.ready(), gate)
        } catch { h.stop(); throw error }
    }

    /// B has been sent on the actual RPC pipe, but it cannot answer yet. A must still install
    /// useful canonical history, including when B's timeout has already marked history incomplete.
    @Test(arguments: [false, true]) func aNewerPendingOrFailedRequestDoesNotSupersedeUsefulOlderHistory(newerTimesOut: Bool) async throws {
        let (h, pi, ready, gate) = try await idleImageFixture()
        defer { h.stop() }
        let held = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { held.signal(); try? Data().write(to: gate) }
        try await h.server.enqueue {
            h.server.rpcThread(forAgent: pi.agent.id)?.beforeHistoryImages = { entered.withValue { $0 = true }; held.wait() }
        }
        let op = UUID(), text = "tools:0 canonical before pending history"
        #expect(try await pi.send(text, operationID: op, from: ready) == .accepted(operationID: op))
        try await eventually("A is hydrating the completed turn") { entered.current }
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.beforeHistoryImages = nil }
        let before = try #require(try await pi.request(.snapshot()).snapshotValue)
        #expect(!before.messages.contains { $0.operationID == op })
        try FileManager.default.removeItem(at: gate)
        let replies = Locked<[Result<RPCResponse, RPCError>]>([]), requests = pi.stdin("get_messages").count
        try await h.server.enqueue {
            h.server.rpcThread(forAgent: pi.agent.id)?.refreshMessages(timeout: newerTimesOut ? 0.05 : 10) { result in
                replies.withValue { $0.append(result) }
            }
        }
        try await eventually("B reached the actual blocked RPC handler") { pi.stdin("get_messages").count > requests }
        if newerTimesOut {
            try await eventually("B timed out") { !replies.current.isEmpty }
            guard case .failure(.timeout) = replies.current.first else { Issue.record("Expected the actual history timeout"); return }
            let incomplete = try #require(try await pi.request(.snapshot()).snapshotValue)
            #expect(incomplete.clips?.history == true)
        } else { #expect(replies.current.isEmpty) }
        held.signal()
        let applied = try await pi.snapshot("A installs canonical history despite B's issuance or failure") {
            !$0.running && $0.messages.contains { $0.operationID == op && $0.role == "user" }
        }
        #expect(applied.messages.count > before.messages.count)
        #expect(applied.messages.filter { $0.operationID == op && $0.role == "user" }.count == 1)
        #expect(applied.clips?.history != true)
        try Data().write(to: gate)
        try await eventually("B callback completed once") { replies.current.count == 1 }
        let refreshed = Locked(false)
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.refreshMessages { _ in refreshed.withValue { $0 = true } } }
        try await eventually("later refresh remains live") { refreshed.current }
        let after = try #require(try await pi.request(.snapshot()).snapshotValue)
        #expect(after.messages == applied.messages && after.clips?.history != true)
        #expect(pi.stdin("prompt").filter { $0["message"] as? String == text }.count == 1)
    }

    @Test func anOldHydratedHistoryCannotEnterANewSessionGeneration() async throws {
        let (h, pi, ready, _) = try await idleImageFixture()
        defer { h.stop() }
        let held = DispatchSemaphore(value: 0), entered = Locked(false), finished = Locked(false)
        defer { held.signal() }
        try await h.server.enqueue {
            let thread = h.server.rpcThread(forAgent: pi.agent.id)!
            thread.beforeHistoryImages = { entered.withValue { $0 = true }; held.wait() }
            thread.refreshMessages { _ in finished.withValue { $0 = true } }
        }
        try await eventually("old session history hydrating") { entered.current }
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.beforeHistoryImages = nil }
        #expect(try await pi.send("resume-nonempty", from: ready).failureCode == nil)
        let switched = try await pi.snapshot("new session canonical history") { $0.piSessionID == "stub-session-2" }
        #expect(switched.generation != ready.generation)
        #expect(switched.messages.map { $0.blocks.map(\.text).joined() } == ["resumed question", "resumed answer"])
        held.signal()
        try await eventually("old generation callback completes") { finished.current }
        let after = try #require(try await pi.request(.snapshot()).snapshotValue)
        #expect(after.generation == switched.generation && after.messages == switched.messages)
        #expect(after.clips?.history != true)
    }

    /// A real old get_messages answer waits for image hydration. A newer answer that contains the
    /// interruption lands first. The old answer must not roll the canonical thread backwards.
    @Test func overlappingHistoryAnswersCannotEraseAnAlreadyCanonicalInterrupt() async throws {
        let (h, pi, running) = try await fixture()
        defer { h.stop() }
        let held = DispatchSemaphore(value: 0), entered = Locked(false), oldFinished = Locked(false), freshFinished = Locked(false)
        defer { held.signal() }
        try await h.server.enqueue {
            let thread = h.server.rpcThread(forAgent: pi.agent.id)!
            thread.beforeHistoryImages = { entered.withValue { $0 = true }; held.wait() }
            thread.refreshMessages { _ in oldFinished.withValue { $0 = true } }
        }
        try await eventually("old image answer gated") { entered.current }
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.beforeHistoryImages = nil }
        let op = UUID(), text = "tools:1 identical-or-not interruption"
        #expect(try await pi.send(text, delivery: .interrupt, operationID: op, from: running) == .accepted(operationID: op))
        _ = try await pi.snapshot("interrupt user started") { $0.running && ($0.messages + $0.provisional).contains { $0.operationID == op && $0.role == "user" && $0.status == nil } }
        pi.finishTool(2)
        _ = try await pi.snapshot("interrupt completed and canonical history applied") { !$0.running && $0.messages.contains { $0.operationID == op && $0.role == "user" } }
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.refreshMessages { _ in freshFinished.withValue { $0 = true } } }
        try await eventually("fresh answer applied") { freshFinished.current }
        let fresh = try #require(try await pi.request(.snapshot()).snapshotValue)
        #expect(fresh.messages.contains { $0.operationID == op && $0.role == "user" })
        let canonicalID = try #require(fresh.messages.first { $0.operationID == op }?.entryID)
        held.signal()
        try await eventually("old answer applied") { oldFinished.current }
        let stale = try #require(try await pi.request(.snapshot()).snapshotValue)
        let visible = (stale.messages + stale.provisional).filter { $0.operationID == op && $0.role == "user" }
        print("OUT_OF_ORDER_IMAGE_HISTORY canonicalID=\(canonicalID) freshHistoryRows=\(fresh.messages.count) oldAppliedRows=\(stale.messages.count) visibleInterrupts=\(visible.count) running=\(stale.running)")
        #expect(visible.count == 1, "A late old image answer must not erase a message already admitted by newer canonical history")
        #expect(visible.first?.entryID == canonicalID)
        #expect(pi.stdin("prompt").filter { $0["message"] as? String == text }.count == 1, "no duplicate send")
        let durable = try JSONSerialization.jsonObject(with: Data(contentsOf: h.dir.appendingPathComponent("history.json"))) as! [[String: Any]]
        let durableUser = durable.filter { ($0["role"] as? String) == "user" && (($0["content"] as? [[String: Any]])?.first?["text"] as? String) == text }
        #expect(durableUser.count == 1, "the canonical source still contains the message: this is display loss, not a proven transcript deletion")
    }
}

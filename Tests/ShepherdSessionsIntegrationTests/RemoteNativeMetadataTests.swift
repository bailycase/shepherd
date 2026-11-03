import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Remote native metadata", .integrationTimeLimit)
struct RemoteNativeMetadataTests {
    @Test func oversizedQuestionsRefuseTheDigestWithoutTruncatingSnapshotAnswers() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let options = [String(repeating: "a", count: 36 * 1024), "No"]
        let script: [String: Any] = ["prompts": ["digest oversized fixture": [["ask": ["title": "Choose", "options": options]]]]]
        try JSONSerialization.data(withJSONObject: script).write(to: r.host.dir.appendingPathComponent("project-script.json"))
        let pi = try await PiAgent.launch(on: r.host)
        let ready = try await pi.snapshot { !$0.piSessionID.isEmpty && $0.supportedActions.contains("send") }
        _ = try await pi.send("digest oversized fixture", from: ready)
        let snapshot = try await pi.snapshot { !$0.dialogs.isEmpty }
        let client = try await r.typed()
        defer { client.disconnect() }
        do {
            _ = try await client.fleetDigest(agentID: pi.agent.id)
            Issue.record("oversized digest accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "too_large") }
        guard case .snapshot(let fallback) = try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()) else {
            Issue.record("expected snapshot fallback"); return
        }
        #expect(fallback.dialogs.first?.options == options)
        #expect(fallback.dialogs == snapshot.dialogs)
    }

    @Test func liveRevisionsIncludeStatusDialogsGoalsQueueAndSubagentMetadata() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        var before = try await t.ready()
        let records = [
            #"{"type":"agent_start"}"#,
            #"{"type":"extension_ui_request","id":"q","method":"select","title":"Choose","options":["Yes","No"]}"#,
            try GoalProjectionTests.widget(NativeGoal(id: GoalProjectionTests.id, text: "Tests pass", state: .checking))
        ]
        for record in records {
            let after = try await t.feedThenSnapshot(record)
            #expect(after.revision > before.revision)
            #expect(FleetDigest(after) != FleetDigest(before))
            guard case .snapshot = await t.request(.snapshot(afterRevision: before.revision)) else {
                Issue.record("metadata change incorrectly returned unchanged"); return
            }
            before = after
        }
        _ = await t.request(.queue(expectedSessionID: before.piSessionID, generation: before.generation,
            operationID: UUID(), action: .setMode(mode: .all)))
        let queued = try await t.snapshot()
        #expect(queued.revision > before.revision)
        await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.setSubagents([ChildRun(runID: "child", label: "Child", state: "running", needsAttention: true)])
                continuation.resume()
            }
        }
        let child = try await t.snapshot()
        #expect(child.revision > queued.revision)
        #expect(FleetDigest(child).subagentsLive == 1)
        #expect(await t.request(.snapshot(afterRevision: child.revision))
            == .unchanged(piSessionID: child.piSessionID, generation: child.generation, revision: child.revision))
    }

    @Test func theDefaultDigestRateBudgetRefusesExcessReads() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host)
        let snapshot = try await pi.ready()
        let raw = try RawRemote(port: r.port)
        try await raw.hello(token: r.token, capabilities: RemoteProtocol.clientCapabilities)
        let session = NativeThreadSession(piSessionID: snapshot.piSessionID, generation: snapshot.generation)
        var burst = Data()
        for id in 2...66 {
            burst.append(try NDJSON.encode(RemoteRequest.fleetDigest(id: id, agentID: pi.agent.id, session: session, revision: snapshot.revision)))
        }
        try raw.sendRaw(burst)
        var refused = 0
        for _ in 2...66 {
            if case .error(_, "busy", _) = try await raw.next() { refused += 1 }
        }
        #expect(refused >= 1, "65 reads in one burst must hit the default 64/second limit")
    }

    @Test func subscriptionsAreScopedAndReplaceable() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host)
        let ready = try await pi.ready()
        let client = try await r.typed()
        guard case .digest(let digest) = try await client.fleetDigest(agentID: pi.agent.id) else { Issue.record("expected live digest"); return }
        #expect(try await client.fleetDigest(agentID: pi.agent.id, session: digest.session, revision: digest.revision)
            == .unchanged(piSessionID: digest.session.piSessionID, generation: digest.session.generation, revision: digest.revision))
        let witness = try await r.typed()
        defer { client.disconnect(); witness.disconnect() }
        let hints = Locked<[AgentID]>([])
        let witnessHints = Locked<[AgentID]>([])
        client.onNativeThreadChanged = { id in hints.withValue { $0.append(id) } }
        witness.onNativeThreadChanged = { id in witnessHints.withValue { $0.append(id) } }
        try await client.subscribeNativeThreads([pi.agent.id])
        try await witness.subscribeNativeThreads([pi.agent.id])
        _ = try await pi.send("hello", from: ready)
        try await eventually("both subscribed clients receive revision invalidation") { !hints.current.isEmpty && !witnessHints.current.isEmpty }
        #expect(hints.current.allSatisfy { $0 == pi.agent.id })
        try await client.subscribeNativeThreads([])
        let count = hints.current.count
        witnessHints.withValue { $0.removeAll() }
        let settled = try await pi.snapshot { !$0.running }
        _ = try await pi.send("hello again", from: settled)
        try await eventually("a subsequent watched revision") { !witnessHints.current.isEmpty }
        #expect(hints.current.count == count, "unsubscribing suppresses pending hints")
        try await client.subscribeNativeThreads([pi.agent.id])
        client.disconnect()
        _ = try await client.connect(host: "127.0.0.1", port: r.port, token: r.token, clientName: "reconnected")
        witnessHints.withValue { $0.removeAll() }
        let reconnected = try await pi.snapshot { !$0.running }
        _ = try await pi.send("after reconnect", from: reconnected)
        try await eventually("the witness sees the reconnect-era revision") { !witnessHints.current.isEmpty }
        #expect(hints.current.count == count, "a new connection starts unsubscribed")
        try await client.subscribeNativeThreads([pi.agent.id])
        let resumed = try await pi.snapshot { !$0.running }
        _ = try await pi.send("after resubscribe", from: resumed)
        try await eventually("explicit resubscription restores hints") { hints.current.count > count }
        let raw = try RawRemote(port: r.port)
        try await raw.hello(token: r.token, capabilities: RemoteProtocol.clientCapabilities)
        try raw.send(.nativeThreadSubscribe(id: 2, agentIDs: Array(repeating: pi.agent.id, count: 65)))
        guard case .error(2, "unsupported", _) = try await raw.next() else { Issue.record("host accepted excessive watch set"); return }
        do {
            try await client.subscribeNativeThreads(Array(repeating: pi.agent.id, count: 65))
            Issue.record("oversized subscription accepted")
        } catch { }
        do {
            try await client.subscribeNativeThreads([AgentID()])
            Issue.record("foreign subscription accepted")
        } catch { }
    }
}

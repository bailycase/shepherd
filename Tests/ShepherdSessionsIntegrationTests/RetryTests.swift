import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Retry (`NativeThreadRequest.retry`): the host runs the status extension's `/shepherd-retry`
/// (the stub answers it as pi does), so the failed turn leaves the thread and pi's history and
/// the retried turn streams in its place, in the same thread.
@Suite("Retry", .integrationTimeLimit)
struct RetryTests {
    private func go(_ h: ScratchServer, _ open: Bool) throws {
        let url = h.dir.appendingPathComponent("flaky-go")
        if open { FileManager.default.createFile(atPath: url.path, contents: nil) } else { try FileManager.default.removeItem(at: url) }
    }

    static func users(_ s: NativeThreadSnapshot, _ text: String) -> [NativeThreadMessage] {
        (s.messages + s.provisional).filter { $0.role == "user" && $0.blocks.map(\.text).joined() == text }
    }

    static func failed(_ s: NativeThreadSnapshot) -> Bool {
        !s.running && s.messages.last { $0.role == "assistant" }?.status == "error"
    }

    /// A turn that failed, settled: its snapshot.
    static func failedTurn(_ pi: PiAgent, _ text: String) async throws -> NativeThreadSnapshot {
        _ = try await pi.send(text, from: try await pi.snapshot())
        return try await pi.snapshot("the turn to fail") { failed($0) && !users($0, text).isEmpty }
    }

    /// Once the turn `text` opened has settled with the stub's recovered reply: its snapshot.
    static func recovered(_ pi: PiAgent, _ text: String) async throws -> NativeThreadSnapshot {
        try await pi.snapshot("the retried turn to settle") { s in
            !s.running && s.messages.last { $0.role == "assistant" }?.blocks.map(\.text) == ["Recovered: \(text)"]
        }
    }

    @Test func aRetriedTurnReplacesTheFailedOneAndShowsThePromptOnce() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        try go(h, true)
        let failed = try await Self.failedTurn(pi, "flaky-hold")
        let prompt = try #require(Self.users(failed, "flaky-hold").first)
        #expect(failed.supportedActions.contains("retry"))

        // The retried turn holds before its reply: the old prompt and its error are gone at once,
        // and the new prompt streams in their place.
        try go(h, false)
        let result = try await pi.request(.retry(expectedSessionID: failed.piSessionID, generation: failed.generation,
                                                 operationID: UUID(), entryID: prompt.entryID))
        #expect(result.acceptedID != nil, "\(result)")
        let streaming = try await pi.snapshot("the retried turn to run") { $0.running && !Self.users($0, "flaky-hold").isEmpty }
        #expect(Self.users(streaming, "flaky-hold").count == 1)
        #expect(!streaming.messages.contains { $0.status == "error" }, "the failed reply left the thread")
        #expect(streaming.piSessionID == failed.piSessionID && streaming.generation == failed.generation, "the same thread")

        try go(h, true)
        let settled = try await pi.snapshot("the retried turn to settle") { s in
            !s.running && s.messages.last { $0.role == "assistant" }?.blocks.map(\.text) == ["Recovered: flaky-hold"]
        }
        #expect(Self.users(settled, "flaky-hold").count == 1, "the prompt once")
        #expect(Self.users(settled, "flaky-hold").first?.entryID != prompt.entryID, "a new message")
        #expect(!settled.messages.contains { $0.status == "error" })
        #expect(settled.generation == failed.generation)

        let at = try #require(prompt.timestamp.map { Int64($0) })
        #expect(pi.stdin("prompt").compactMap { $0["message"] as? String } == ["flaky-hold", "/shepherd-retry \(at)"],
                "pi got the command, never the prompt again")
        // pi's composer lists commands; this one is Shepherd's own.
        #expect(!(settled.commands ?? []).contains { $0.name == "shepherd-retry" })
    }

    @Test func retryIsRefusedWhileTheAgentWorksAndForAnythingButTheLatestTurn() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        try go(h, true)
        let failed = try await Self.failedTurn(pi, "flaky-hold")
        let prompt = try #require(Self.users(failed, "flaky-hold").first)

        // Working: a new turn holds before its reply.
        try go(h, false)
        _ = try await pi.send("flaky-hold again", from: failed)
        let working = try await pi.snapshot("the next turn to run") { $0.running }
        let newest = try #require(Self.users(working, "flaky-hold again").first)
        let busy = try await pi.request(.retry(expectedSessionID: working.piSessionID, generation: working.generation,
                                               operationID: UUID(), entryID: newest.entryID))
        #expect(busy.failureCode == "busy")

        try go(h, true)
        let settled = try await pi.snapshot("the next turn to settle") { s in
            !s.running && s.messages.last { $0.role == "assistant" }?.blocks.map(\.text) == ["Recovered: flaky-hold again"]
        }
        // The first turn is no longer the latest: retrying it would drop the one after it.
        let older = try await pi.request(.retry(expectedSessionID: settled.piSessionID, generation: settled.generation,
                                                operationID: UUID(), entryID: prompt.entryID))
        #expect(older.failureCode == "not_latest")
        #expect(!pi.stdin("prompt").contains { ($0["message"] as? String)?.hasPrefix("/shepherd-retry") == true })
        let after = try await pi.snapshot()
        #expect(after.messages == settled.messages, "nothing moved")
    }
}

@Suite("Retry in the store", .mainActorExclusive)
@MainActor
struct RetryStoreTests {
    /// Through a remote client's thread store: a host that retries in place gets the command; one
    /// that doesn't (no `native.retry.v1`) gets the prompt again, as before.
    @Test(arguments: [true, false])
    func aRemoteThreadRetriesInPlaceOnlyOnAHostThatCan(inPlace: Bool) async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        if !inPlace {
            remote.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.nativeRetryCapability }
        }
        let pi = try await PiAgent.launch(on: remote.host)
        _ = try await pi.ready()
        FileManager.default.createFile(atPath: remote.host.dir.appendingPathComponent("flaky-go").path, contents: nil)
        _ = try await RetryTests.failedTurn(pi, "flaky")

        let client = try await remote.typed()
        defer { client.disconnect() }
        let store = NativeThreadStore()
        let agentID = pi.agent.id
        let task = Task { await store.run { try await client.nativeThread(agentID: agentID, request: $0) } }
        defer { task.cancel() }
        try await eventuallyOnMain("the failed turn's Retry") { store.rows.last.map { store.canRetry($0, running: store.settledRunning) } == true }
        #expect(store.supportedActions.contains("retry") == inPlace)
        let row = try #require(store.rows.last)
        await store.retry(row)

        let settled = try await RetryTests.recovered(pi, "flaky")
        let prompts = pi.stdin("prompt").compactMap { $0["message"] as? String }
        if inPlace {
            #expect(prompts.count == 2 && prompts[1].hasPrefix("/shepherd-retry "))
            #expect(RetryTests.users(settled, "flaky").count == 1)
        } else {
            #expect(prompts == ["flaky", "flaky"], "the older host's fallback: the prompt again")
            #expect(RetryTests.users(settled, "flaky").count == 2)
        }
    }
}

private extension NativeThreadResult {
    var acceptedID: UUID? {
        if case .accepted(let id) = self { return id }
        return nil
    }
}

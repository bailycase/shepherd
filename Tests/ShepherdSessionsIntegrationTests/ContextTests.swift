import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// What fills an agent's context (`NativeThreadSnapshot.context`) and pi's compactions, served
/// from the stub pi: the total is pi's, the split and the largest items the host's estimate, and
/// Compact now is pi's `compact`. The host never sends `set_auto_compaction`, which would write
/// the user's pi settings.
@Suite("Context and compaction", .integrationTimeLimit)
struct ContextTests {
    private func compact(_ pi: PiAgent, _ instructions: String? = nil, from s: NativeThreadSnapshot) async throws -> NativeThreadResult {
        try await pi.request(.compact(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), instructions: instructions))
    }

    /// pi's total and window, the auto-compact mark from pi's settings (the project's here), and
    /// the host's split and largest items scaled to pi's total.
    @Test func theSnapshotCarriesPisTotalAndTheHostsSplit() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let settings = h.dir.appendingPathComponent(".pi")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data(#"{"compaction":{"reserveTokens":20000,"keepRecentTokens":15000}}"#.utf8).write(to: settings.appendingPathComponent("settings.json"))
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        #expect(idle.supportedActions.contains("compact"))
        #expect(idle.context?.tokens == 60_000 && idle.context?.window == 200_000)

        _ = try await pi.send("context", from: idle)
        let s = try await pi.snapshot("the sized context") { $0.context?.tokens == 42_000 && $0.context?.split?.instructionFiles == ["AGENTS.md"] }
        let context = try #require(s.context)
        #expect(context.autoCompact == true && context.autoCompactAt == 180_000 && context.keepRecent == 15_000)
        let split = try #require(context.split)
        #expect(abs(split.total - 42_000) <= 4, "the split is scaled to pi's total")
        #expect(split.toolResults > split.messages && split.instructions > 0 && split.system > 0)
        #expect(context.largest.map(\.label) == ["DesktopNativeThreadView.swift", "swift test --filter NativePresentationTests"])
        #expect(context.largest.map(\.entryID) == ["t:call_read", "t:call_test"])
        #expect(context.largest.map(\.kind) == [.file, .command])
        #expect(!s.messages.contains { $0.role == "system" }, "pi's system prompt is not a thread row")
        #expect(pi.stdin("set_auto_compaction").isEmpty)
    }

    /// Compact now sends pi's `compact` with what to keep; the thread shows the compaction running,
    /// then where it happened with what the agent kept, and the ring the agent's estimate until
    /// its next reply.
    @Test func compactNowKeepsWhatTheUserAskedAndLandsWhereItHappened() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        // A run like pi's own (every message stamped), so the kept messages keep their ids.
        _ = try await pi.send("tools:0 first turn", from: idle)
        let turned = try await pi.snapshot("the first turn") { !$0.running && $0.messages.count == 4 }

        #expect(try await compact(pi, "  Keep the files I changed (hold)  ", from: turned).failureCode == nil)
        let sent = try await pi.waitForStdin("compact")
        #expect(sent["customInstructions"] as? String == "Keep the files I changed (hold)")
        let running = try await pi.snapshot("the compaction running") { $0.context?.compacting != nil }
        #expect(running.context?.compacting?.reason == .manual)
        #expect(running.provisional.last?.compaction?.phase == .running)
        #expect(try await compact(pi, from: running).failureCode == "busy", "one compaction at a time")

        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("compact-done").path, contents: nil)
        let done = try await pi.snapshot("the compaction in history") { s in
            s.context?.compacting == nil && s.messages.contains { $0.role == "compactionSummary" } && s.provisional.isEmpty
        }
        let summary = try #require(done.messages.first { $0.role == "compactionSummary" })
        #expect(summary.compaction?.reason == .manual && summary.compaction?.tokensBefore == 60_000 && summary.compaction?.tokensAfter == 23_000)
        #expect(summary.compaction?.summary?.hasSuffix("Kept: Keep the files I changed (hold)") == true)
        #expect(done.messages.map(\.entryID).prefix(2) == ["user:1733234567890", "assistant:1733234567891"],
                "what was summarized stays readable above the compaction")
        #expect(done.messages.last?.role == "compactionSummary", "after the messages pi kept")
        #expect(done.context?.tokens == nil && done.context?.estimate == 23_000 && done.context?.before == 60_000)
        #expect(done.context?.summaryEntryID == summary.entryID)

        _ = try await pi.send("next turn", from: done)
        let exact = try await pi.snapshot("an exact number after the next reply") { $0.context?.tokens == 60_000 }
        #expect(exact.context?.estimate == nil)
    }

    /// pi stops a run to compact: the host takes Compact now only while the agent is idle.
    @Test func compactingWaitsForTheAgentToStop() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        _ = try await pi.send("slow", from: idle)
        let streaming = try await pi.snapshot("the turn streaming") { $0.running }
        #expect(try await compact(pi, from: streaming).failureCode == "busy")
        #expect(pi.stdin("compact").isEmpty)
        pi.release(1)
        pi.release(2)
    }

    /// pi compacting on its own after a turn: the line says so where it happened.
    @Test func anAutomaticCompactionIsSaidAsOne() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        _ = try await pi.send("auto-compact", from: idle)
        let done = try await pi.snapshot("the automatic compaction") { s in
            !s.running && s.messages.contains { $0.compaction?.reason == .threshold }
        }
        let summary = try #require(done.messages.first { $0.role == "compactionSummary" })
        #expect(summary.compaction?.tokensAfter == 23_000)
        #expect(done.messages.first?.entryID == "user:1733234567890", "the conversation before it stays")
    }

    /// A compaction that is stopped changes nothing and says so until the next run; one that
    /// fails says why.
    @Test func aStoppedOrFailedCompactionSaysNothingChanged() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        _ = try await pi.send("compact-abort", from: idle)
        let stopped = try await pi.snapshot("the stopped compaction") { $0.provisional.last?.compaction?.phase == .stopped }
        #expect(stopped.context?.compacting == nil)
        #expect(!stopped.messages.contains { $0.role == "compactionSummary" })

        // The stub's session is two messages: too small to compact.
        #expect(try await compact(pi, from: stopped).failureCode == nil)
        let failed = try await pi.snapshot("the failed compaction") { $0.provisional.last?.compaction?.phase == .failed }
        #expect(failed.provisional.last?.compaction?.error == "Compaction failed: Nothing to compact (session too small)")
    }

    /// Over the remote listener: the snapshot's context and Compact now, gated by the host's
    /// `native.context.v1`.
    @Test func remoteClientsSeeTheContextAndCompact() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host)
        _ = try await pi.ready()
        let client = try await remote.typed()
        #expect(client.capabilities.contains(RemoteProtocol.nativeContextCapability))
        guard case .snapshot(let s) = try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()) else {
            Issue.record("no snapshot")
            return
        }
        #expect(s.context?.window == 200_000)
        let result = try await client.nativeThread(agentID: pi.agent.id, request: .compact(
            expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), instructions: "keep it"))
        #expect(result.failureCode == nil)
        let sent = try await pi.waitForStdin("compact")
        #expect(sent["customInstructions"] as? String == "keep it")
    }
}

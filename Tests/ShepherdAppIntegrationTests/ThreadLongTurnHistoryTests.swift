import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A turn longer than the host's page of 50 messages, against a real server and a stub pi
/// (`RealThreadRig`). While it runs, its calls are live rows; when pi settles they are saved, and
/// the newest page then starts inside the turn. The thread must keep the prompt and the history
/// above it: before the fix it shrank to the last reply, so the transcript looked emptied until the
/// reader scrolled up for older pages (the Dev app showed 5 rows drop to 1 after a 30-call turn).
@Suite("A long turn keeps its history", .serialized, .mainActorExclusive, .integrationTimeLimit)
@MainActor
struct ThreadLongTurnHistoryTests {
    @Test func aTurnLongerThanAPageKeepsItsPromptAndTheHistoryAboveIt() async throws {
        let rig = try await RealThreadRig(size: ThreadTailFlowTests.short, turns: 8, mix: .moderate)
        defer { rig.close() }
        let before = rig.store.rows.map(\.id)
        let calls = 40
        rig.store.draft = "tools:\(calls) a long turn"
        await rig.store.send()
        try await eventuallyOnMain("the run to start") { rig.store.running }
        for k in 1...calls { rig.release(k) }
        try await eventuallyOnMain("the turn to settle with its saved reply", timeout: .seconds(30)) {
            !rig.store.running && rig.store.messages.contains { $0.blocks.contains { $0.text.hasPrefix("Reply to tools:\(calls)") } }
        }
        let rows = rig.store.rows.map(\.id)
        #expect(Array(rows.prefix(before.count)) == before, "the rows above the turn are still there")
        #expect(rig.store.rows.contains { $0.isUser && $0.turn.messages.contains { $0.blocks.contains { $0.text.hasPrefix("tools:\(calls)") } } },
                "the turn's prompt is still in the thread")
        #expect(rows.count == before.count + 2, "one prompt row and one reply row were added: \(rows)")
    }
}

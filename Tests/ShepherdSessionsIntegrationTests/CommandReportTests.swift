import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

extension ThreadEventTests.Thread {
    /// Sends `text` as the user would, returning once pi has answered the prompt.
    func sendAsUser(_ text: String, delivery: NativeThreadDelivery = .followUp) async {
        await withCheckedContinuation { continuation in
            queue.async { self.state.send(id: UUID(), text: text, delivery: delivery, images: []) { _ in continuation.resume() } }
        }
    }

    /// The first snapshot satisfying `condition`, polling until it appears.
    func settle(_ what: String, _ condition: @escaping (NativeThreadSnapshot) -> Bool) async throws -> NativeThreadSnapshot {
        var latest: NativeThreadSnapshot?
        try await eventually(what) {
            latest = await request(.snapshot()).snapshotValue
            return latest.map(condition) ?? false
        }
        return try #require(latest)
    }
}

/// The bundled extensions answer a command with a displayed message (`pi.sendMessage`, no turn),
/// which pi persists and announces with message events. The stub's `/session-name report <text>`
/// is that command (see stub-pi.py).
@Suite("Command reports", .integrationTimeLimit)
struct CommandReportTests {
    typealias Thread = ThreadEventTests.Thread

    @Test func aDisplayedMessageAnIdleCommandSendsShowsWithoutATurn() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await t.sendAsUser("/session-name report workflow w · complete")

        let s = try await t.settle("the report") { $0.messages.count == 3 }
        let row = try #require(s.messages.last)
        #expect(row.role == "custom" && row.blocks == [NativeThreadBlock(kind: .text, text: "workflow w · complete")])
        #expect(!s.running && s.provisional.isEmpty)
        #expect(nativeTurnItems([row]) == [.note("workflow w · complete")])
    }
}

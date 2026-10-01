import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// What an extension command the user ran says back. pi's RPC mode has no toast, and most
/// commands answer with a `notify`: the thread keeps one that answers a command the user just
/// sent, as a row, and still drops a toast nobody asked for. The stub's `/session-name` is the
/// extension command (see stub-pi.py), and its first word picks what it says.
@Suite("Command notices", .integrationTimeLimit)
struct CommandNoticeTests {
    typealias Thread = ThreadEventTests.Thread

    private static let agentEnd = #"{"type":"agent_end","messages":[],"willRetry":false}"#

    /// Returns once pi has answered a request sent now: it answers in order, so everything it
    /// emitted before is the host's by then.
    private func barrier(_ t: Thread) async {
        await withCheckedContinuation { continuation in
            t.queue.async { t.session.request(.getState) { _ in continuation.resume() } }
        }
    }

    /// The rows the notices make, wherever the snapshot shows them.
    private func notices(_ s: NativeThreadSnapshot) -> [NativeThreadMessage] {
        (s.messages + s.provisional).filter { $0.entryID.hasPrefix("n:") }
    }

    @Test func aToastDuringACommandTheUserSentBecomesARow() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await t.sendAsUser("/session-name info Session named")

        let s = try await t.settle("the row") { !notices($0).isEmpty }
        let row = try #require(notices(s).first)
        #expect(notices(s).count == 1)
        #expect(row.role == "custom" && row.blocks == [NativeThreadBlock(kind: .text, text: "Session named")])
        #expect(s.provisional.map(\.entryID) == [row.entryID], "it shows where the user is looking, until history places it")
        #expect(s.messages.count == 2, "pi's history is its own")
    }

    @Test(arguments: ["warning", "error"])
    func aWarningOrAnErrorSaysSoByItsRole(level: String) async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await t.sendAsUser("/session-name \(level) It went \(level)")

        let row = try #require(notices(try await t.settle("the row") { !notices($0).isEmpty }).first)
        #expect(row.role == level && row.blocks.first?.text == "It went \(level)")
        #expect(nativeTurnItems([row]) == [.note("\(level) · It went \(level)")], "older clients draw it as a note too")
    }

    @Test func aToastNobodyAskedForIsStillDropped() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(#"{"type":"extension_ui_request","id":"1","method":"notify","message":"Ponytail loaded","notifyType":"info"}"#)
        #expect(notices(try await t.snapshot()).isEmpty)

        // pi's own turn is no command: the toast it brings (the stub's "widgets" sends one) is dropped too.
        await t.sendAsUser("widgets")
        await barrier(t)
        let s = try await t.snapshot()
        #expect(s.widgets?.map(\.key) == ["w"], "the turn's other output arrived")
        #expect(notices(s).isEmpty)
    }

    @Test func aToastJustAfterTheCommandIsAnsweredStillCounts() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await t.sendAsUser("/session-name late Finished in the background")

        let s = try await t.settle("the late row") { !notices($0).isEmpty }
        #expect(notices(s).map { $0.blocks.first?.text } == ["Finished in the background"])
    }

    @Test func aToastAfterTheGraceIsDropped() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        t.queue.sync { t.state.commandNoticeGrace = 0.02 }
        await t.sendAsUser("/session-name quiet")
        try await eventually("the command's window to close") { t.queue.sync { t.state.commandWindows.isEmpty } }

        try await t.feed(#"{"type":"extension_ui_request","id":"1","method":"notify","message":"Too late","notifyType":"info"}"#)
        #expect(notices(try await t.snapshot()).isEmpty)
    }

    @Test func aRowSurvivesTheHistoryRefreshOnceAndInPlace() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await t.sendAsUser("/session-name info Remember this")
        _ = try await t.settle("the live row") { !notices($0).isEmpty }
        let id = try #require(notices(try await t.snapshot()).first?.entryID)

        for _ in 1...2 {
            try await t.feed(Self.agentEnd)
            await barrier(t)
            let s = try await t.snapshot()
            #expect(s.provisional.isEmpty, "history placed it")
            #expect(notices(s).map(\.entryID) == [id], "one row under the same id, never a second")
            #expect(s.messages.map(\.entryID).last == id, "after what pi had said")
            #expect(s.messages.count == 3)
        }
    }

    @Test func aCommandThatFailsSaysSoInTheThread() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await t.sendAsUser("/session-name fail it broke")

        let row = try #require(notices(try await t.settle("the failure") { !notices($0).isEmpty }).first)
        #expect(row.role == "error" && row.blocks.first?.text == "/session-name failed: it broke")
    }

    /// pi runs an extension command at once, even while a run goes on; a steer is how the host
    /// sends one then.
    @Test func aCommandSentWhileTheRunGoesOnIsAnsweredToo() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(#"{"type":"agent_start"}"#)
        await t.sendAsUser("/session-name warning Mid-run", delivery: .steer)

        let s = try await t.settle("the row") { !notices($0).isEmpty }
        #expect(notices(s).map(\.role) == ["warning"])
        #expect(s.queue?.items.isEmpty == true, "a command leaves nothing in the queue")
    }

    @Test func aThreadKeepsTheNewestNoticesOnly() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        t.queue.sync { t.state.commandNoticeGrace = 60 }
        await t.sendAsUser("/session-name quiet")
        for i in 0..<(RPCThreadState.noticeLimit + 4) {
            try await t.feed(#"{"type":"extension_ui_request","id":"n\#(i)","method":"notify","message":"toast \#(i)","notifyType":"info"}"#)
        }
        let s = try await t.snapshot()
        #expect(notices(s).count == RPCThreadState.noticeLimit)
        #expect(notices(s).first?.blocks.first?.text == "toast 4" && notices(s).last?.blocks.first?.text == "toast \(RPCThreadState.noticeLimit + 3)")
    }

    @Test func aNoticeBelongsToItsSessionAndGoesWithIt() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await t.sendAsUser("/session-name info Before the switch")
        _ = try await t.settle("the row") { !notices($0).isEmpty }
        await t.sendAsUser("newsession")

        _ = try await t.settle("the new session") { $0.piSessionID == "stub-session-2" }
        await barrier(t)
        #expect(notices(try await t.snapshot()).isEmpty)
    }

    /// The whole way: a send to the server, the stub's command, the same row for the host's own
    /// client and a remote one (no new request or field: an older client draws it as a note).
    @Test func everyClientSeesTheSameRow() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host)
        _ = try await pi.ready()
        let s = try await pi.snapshot("the command list") { $0.commands != nil }
        #expect(try await pi.send("/session-name warning Check the build", from: s).failureCode == nil)

        let local = try await pi.snapshot("the row") { $0.provisional.contains { $0.entryID.hasPrefix("n:") } }
        let row = try #require(local.provisional.first { $0.entryID.hasPrefix("n:") })
        #expect(row.role == "warning" && row.blocks.first?.text == "Check the build")
        #expect(pi.stdin("prompt").map { $0["message"] as? String } == ["/session-name warning Check the build"])

        let client = try await remote.typed()
        let seen = try #require(try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue)
        #expect(seen.provisional.first { $0.entryID == row.entryID } == row)
    }
}

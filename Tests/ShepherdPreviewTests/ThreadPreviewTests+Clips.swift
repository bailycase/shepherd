import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

/// What a thread says when its snapshot shortened something (docs/native-thread.md › RPCThreadState › Clipped), in the
/// banner's own style, from snapshots a host served: its live rows, questions and history through the
/// host's budget, over the wire's JSON, into the store the thread reads. Older pages to scroll up to
/// and a long message draw no banner at all.
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    static let clipWide = CGSize(width: 1000, height: 760)
    static let clipNarrow = CGSize(width: 420, height: 760)

    /// What a host serves for `base`: `live` and `dialogs` as the running turn and the questions it holds, through
    /// the host's own budget, with the facts it already held in `clips`, then over the wire.
    static func served(_ base: NativeThreadSnapshot, live: [NativeThreadMessage] = [], dialogs: [NativeThreadDialog] = [],
                       clips: NativeThreadClips? = nil) throws -> NativeThreadSnapshot {
        func sized<T: Encodable>(_ value: T) -> RPCThreadState.Sized<T> { RPCThreadState.Sized(value: value, bytes: RPCThreadState.bytes(value)) }
        var held = base
        let history = base.messages.map { sized($0) }
        held.messages = []
        held.provisional = []
        held.dialogs = []
        held.clips = clips
        held.clipped = clips != nil
        let (value, _) = RPCThreadState.budget(held, baseBytes: RPCThreadState.bytes(held), active: live.map { sized($0) },
                                               dialogs: dialogs.map { sized($0) }, historyEnd: history.count) { history[$0] }
        return try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONEncoder().encode(value))
    }

    /// A thread short enough to show from its top, where the notices sit above its first turn.
    static func shortThread(running: Bool = false) -> NativeThreadSnapshot {
        var snapshot = Threads.empty
        snapshot.running = running
        snapshot.messages = [
            NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Migrate the ledger to the new schema, then run the checks.")]),
            NativeThreadMessage(entryID: "a", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Starting with the migration. The checks run once it applies cleanly.")]),
        ]
        return snapshot
    }

    /// A turn's output that weighs 12 KiB, the way a tool that printed a lot is.
    static func bigRow(_ index: Int) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "provisional:tool:big\(index)", role: "toolResult",
                            blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "build output line \(index)\n", count: 480))],
                            toolName: "bash", toolCallID: "big\(index)", argumentsText: "{\"command\":\"swift build\"}", status: "complete")
    }

    /// A running turn whose output is more than the snapshot holds: the oldest rows go, the call that runs stays.
    static var heavyTurn: [NativeThreadMessage] { (0..<14).map(bigRow) + Threads.running.provisional }

    /// Questions waiting on the user that do not all fit.
    static var heavyQuestions: [NativeThreadDialog] {
        (0..<4).map { NativeThreadDialog(id: "q\($0)", kind: .confirm, title: "Apply migration \($0)?", message: String(repeating: "step \($0): rewrite the table\n", count: 1400)) }
    }

    private func renderClips(_ surface: String, _ snapshot: NativeThreadSnapshot, lines: [String], size: CGSize = clipWide) async throws {
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        let store = fixture.store
        try await Preview.renderMatrix(surface, size: size, scales: [1, 1.3], ready: {
            store.ready && !store.rows.isEmpty && (store.clipNotice?.lines ?? []) == lines
        }) {
            fixture.thread(title: "Migrate the ledger")
        }
    }

    @Test func unreadHistoryTellsWhatIsMissingAndWhenItReturns() async throws {
        let snapshot = try Self.served(Self.shortThread(), clips: NativeThreadClips(history: true))
        #expect(snapshot.clipped && snapshot.clips == NativeThreadClips(history: true))
        try await renderClips("thread-clips-history", snapshot, lines: [NativeClipNotice.history])
    }

    @Test func aTurnsHiddenOutputIsSaidWhileItRuns() async throws {
        let snapshot = try Self.served(Self.shortThread(running: true), live: Self.heavyTurn)
        let left = try #require(snapshot.clips?.live)
        #expect(left > 0 && snapshot.provisional.count + left == Self.heavyTurn.count && snapshot.provisional.last?.toolCallID == "c6")
        try await renderClips("thread-clips-live", snapshot, lines: [NativeClipNotice.live])
    }

    @Test func questionsThatDoNotFitAreCounted() async throws {
        let snapshot = try Self.served(Self.shortThread(running: true), dialogs: Self.heavyQuestions)
        let left = try #require(snapshot.clips?.questions)
        #expect(left > 0 && snapshot.dialogs.count + left == Self.heavyQuestions.count)
        try await renderClips("thread-clips-questions", snapshot, lines: [left == 1 ? NativeClipNotice.oneQuestion : NativeClipNotice.questions(left)])
    }

    @Test(arguments: [true, false])
    func everyCauseAtOnceStacksOneLineEach(wide: Bool) async throws {
        let snapshot = try Self.served(Self.shortThread(running: true), live: Self.heavyTurn, dialogs: Self.heavyQuestions, clips: NativeThreadClips(history: true))
        let left = try #require(snapshot.clips?.questions)
        #expect(snapshot.clips?.history == true && (snapshot.clips?.live ?? 0) > 0 && left > 0)
        let lines = [NativeClipNotice.history, NativeClipNotice.live, left == 1 ? NativeClipNotice.oneQuestion : NativeClipNotice.questions(left)]
        try await renderClips(wide ? "thread-clips-all" : "thread-clips-all-narrow", snapshot, lines: lines, size: wide ? Self.clipWide : Self.clipNarrow)
    }

    @Test func anOlderHostsFlagAloneSaysOnlyThatSomethingIsClipped() async throws {
        var snapshot = Self.shortThread()
        snapshot.clipped = true
        try await renderClips("thread-clips-older-host", snapshot, lines: [NativeClipNotice.unknown])
    }

    /// Older pages to scroll up to, and a message whose own text was shortened: no banner. The long message says so
    /// on its row.
    @Test func olderPagesAndALongMessageDrawNoBanner() async throws {
        var snapshot = Self.shortThread()
        snapshot.olderCursor = snapshot.messages.first?.entryID
        let long = NativeThreadMessage(entryID: "long", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "log line\n", count: 80))],
                                       toolName: "bash", toolCallID: "long", argumentsText: "{\"command\":\"swift test\"}", status: "complete", truncated: true)
        snapshot.messages.append(long)
        let served = try Self.served(snapshot)
        #expect(served.olderCursor != nil && !served.clipped && served.clips == nil)
        try await renderClips("thread-clips-none", served, lines: [])
    }
}

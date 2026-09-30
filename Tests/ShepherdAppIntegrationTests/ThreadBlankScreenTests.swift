import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A long thread never draws blank while it follows its tail: not after a send, not as the turn
/// streams, and not as it finishes (DESIGN.md › Thread). Read from what the window draws, not
/// from the scroll view's numbers: the failure this guards left the scroll view reporting the
/// tail (distance 0) while the lazy stack had placed its rows elsewhere and the viewport drew
/// nothing but the composer. It needed `defaultScrollAnchor(.bottom)` over a stack of estimated
/// row heights and a window of modest height, and showed on macOS 27 (with a build for the
/// macOS 26 SDK too) in the 900×600 window and not in a tall one. From 27 the thread sets no
/// anchor (`ThreadTailAnchor`). macOS 26 still anchors, and CI's runner shows the same blank
/// there, even at the opening, in the short windows: a known issue on 26 until the thread can
/// reach its tail there without `scrollTo` (which builds every row of a long thread). The tall
/// window is the control everywhere.
///
/// Every test runs a real `ThreadView` over a `QueueFixture` host in an off-screen window, the
/// host changing the way pi's does, and looks at the window after each change.
@Suite("Thread blank screen", .serialized, .mainActorExclusive)
@MainActor
struct ThreadBlankScreenTests {
    static let base = 1_700_000_000_000.0

    // MARK: Rig

    /// A thread in a window of `size`, with a long history, fed the host's snapshots.
    @MainActor
    final class Rig {
        let store = NativeThreadStore()
        let host: QueueFixture
        let window: OffscreenWindow
        let size: CGSize
        private(set) var messages: [NativeThreadMessage]
        private var revision: UInt64 = 1

        init(turns: Int, size: CGSize) {
            self.size = size
            messages = ThreadBlankScreenTests.history(turns: turns)
            host = QueueFixture(ThreadBlankScreenTests.snapshot(messages, revision: 1))
            window = OffscreenWindow(size: size, dark: true)
            window.show(ThreadView(store: store, active: true, isFocused: false, request: { [host] in host.answer($0) },
                                   commandKey: "blank", listModels: { .empty }))
        }

        func close() {
            store.stop()
            window.close()
        }

        /// Loaded and drawing its tail.
        func open() async throws {
            try await eventuallyOnMain("the thread to load") { store.ready }
            try await expectTail("opening")
        }

        var scrollView: NSScrollView? { ListPerf.scrollView(in: window) }

        /// Where the thread's clip view stands against its content.
        var reading: Reading? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let clip = scroll.contentView
            return Reading(content: document.bounds.height, offset: clip.bounds.origin.y, viewport: clip.bounds.height,
                           insetTop: scroll.contentInsets.top, insetBottom: scroll.contentInsets.bottom)
        }

        /// Pixels in the thread above the composer that differ from its background: zero means
        /// the thread draws nothing.
        var ink: Int {
            let inset = (reading?.insetBottom ?? 0) + 24
            let capture = FrameTimer.capture(window, CGRect(x: 0, y: 0, width: size.width, height: size.height - inset))
            return capture.data.withUnsafeBytes { raw -> Int in
                let p = raw.bindMemory(to: UInt8.self)
                let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
                var count = 0
                for y in 0..<capture.height {
                    let row = y * capture.bytesPerRow
                    for x in 0..<capture.width {
                        let i = row + x * 4
                        if abs(Int(p[i]) - r) > 12 || abs(Int(p[i + 1]) - g) > 12 || abs(Int(p[i + 2]) - b) > 12 { count += 1 }
                    }
                }
                return count
            }
        }

        /// The host changes: `change` edits the conversation, and the thread pulls the new
        /// snapshot, as a pushed revision does.
        func publish(running: Bool = true, provisional: [NativeThreadMessage] = [], turnChanges: [ChangesTurn]? = nil,
                     queue: [NativeQueuedMessage]? = nil, _ change: (inout [NativeThreadMessage]) -> Void = { _ in }) async {
            change(&messages)
            revision += 1
            var next = ThreadBlankScreenTests.snapshot(messages, provisional: provisional, running: running, revision: revision,
                                                      turnChanges: turnChanges)
            next.queue = NativeQueue(items: queue ?? host.queue, mode: .all)
            host.snapshot = next
            await store.refresh()
            window.layout()
        }

        /// Waits for the thread to draw its tail: something on screen, the view at the tail and
        /// never past it. A frame or two of a half-laid-out thread is not the failure; a thread
        /// that stays blank is.
        func expectTail(_ what: String) async throws {
            var last: Reading?
            var drawn = 0
            do {
                try await eventuallyOnMain("\(what): the thread to draw its tail", timeout: .seconds(4), poll: .milliseconds(16)) {
                    window.layout()
                    guard let reading else { return false }
                    last = reading
                    drawn = ink
                    return drawn > 0 && reading.distance >= -2 && reading.distance <= NativeScrollFollower.threshold
                }
            } catch {
                throw TimedOut(what: "\(what): the thread to draw its tail (\(drawn) pixels drawn; \(last.map(String.init(describing:)) ?? "no scroll view"))")
            }
        }
    }

    struct Reading: CustomStringConvertible {
        var content: CGFloat
        var offset: CGFloat
        var viewport: CGFloat
        var insetTop: CGFloat
        var insetBottom: CGFloat

        /// How far the visible bottom sits above the end of the content: 0 at the tail,
        /// negative past it.
        var distance: CGFloat { content - (offset + viewport - insetBottom) }

        var description: String {
            "content \(Int(content)), offset \(Int(offset)), viewport \(Int(viewport)), insets \(Int(insetTop))/\(Int(insetBottom)), \(Int(distance)) above the tail"
        }
    }

    // MARK: Fixtures

    static func snapshot(_ messages: [NativeThreadMessage], provisional: [NativeThreadMessage] = [], running: Bool = false,
                         revision: UInt64, turnChanges: [ChangesTurn]? = nil) -> NativeThreadSnapshot {
        var snapshot = ThreadFixture.snapshot(messages, provisional: provisional, running: running, revision: revision)
        snapshot.turnChanges = turnChanges
        snapshot.supportedActions.append("queue")
        return snapshot
    }

    static func prose(_ paragraphs: Int, _ n: Int) -> String {
        (0..<paragraphs).map { "Paragraph \($0) of reply \(n), long enough to wrap onto a second line or two inside the column of the thread." }
            .joined(separator: "\n\n")
    }

    static func code(_ n: Int) -> String {
        "```swift\n" + (0..<(6 + n % 9)).map { "    let value\($0) = compute(\($0)) // step \(n)" }.joined(separator: "\n") + "\n```"
    }

    static func tool(_ id: String, _ name: String, _ args: [String: Any], output: String, at: Double, status: String = "complete",
                     provisional: Bool = false) -> NativeThreadMessage {
        let data = try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return NativeThreadMessage(entryID: provisional ? "provisional:tool:\(id)" : "t-\(id)", role: "toolResult",
                                   blocks: output.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: output)],
                                   toolName: name, toolCallID: id, argumentsText: String(data: data, encoding: .utf8), status: status,
                                   timestamp: at + 1000, startedAt: at)
    }

    static func user(_ id: String, _ text: String, at: Double) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false, timestamp: at)
    }

    static func reply(_ id: String, _ text: String, status: String? = nil, at: Double) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)], status: status,
                            truncated: false, timestamp: at)
    }

    /// A settled turn: the question, some tool calls, and an answer with prose and a code block,
    /// so rows differ in height the way a real thread's do.
    static func turn(_ n: Int) -> [NativeThreadMessage] {
        let at = base + Double(n) * 60_000
        var out = [user("u\(n)", "Question \(n): please do the thing and explain it.", at: at)]
        for k in 0..<(1 + n % 4) {
            out.append(tool("c\(n)-\(k)", k.isMultiple(of: 2) ? "read" : "bash",
                            k.isMultiple(of: 2) ? ["path": "Sources/File\(n)\(k).swift"] : ["command": "swift test --filter T\(k)"],
                            output: (0..<(3 + (n + k) % 12)).map { "output line \($0)" }.joined(separator: "\n"), at: at + 1000))
        }
        out.append(reply("a\(n)", prose(1 + n % 5, n) + "\n\n" + code(n), at: at + 5000))
        return out
    }

    static func history(turns: Int) -> [NativeThreadMessage] { (0..<turns).flatMap(turn) }

    /// The host's record of a finished turn: its "Edited 5 files" card.
    static func recorded(promptAt: Double) -> ChangesTurn {
        ChangesTurn(messageTimestamp: promptAt, startedAt: promptAt, endedAt: promptAt + 60_000, state: .ready,
                    files: (0..<5).map { ChangesFile(path: "Sources/Edit\($0).swift", status: .modified, added: 10, removed: 3) },
                    added: 50, removed: 15, canUndo: true)
    }

    static func streamingReply(_ paragraphs: Int) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant",
                            blocks: [NativeThreadBlock(kind: .text, text: prose(paragraphs, 99))], status: "streaming", truncated: false)
    }

    /// Short windows are where it happened; the tall one is the control.
    nonisolated static let sizes = [CGSize(width: 900, height: 600), CGSize(width: 1100, height: 700), CGSize(width: 1200, height: 900)]

    // MARK: Sequences

    /// A thread of a long history in a window of `size`, open and drawing its tail, for `body`.
    /// Short windows still open blank where the thread anchors natively (macOS 26).
    static func withRig(size: CGSize, _ body: (Rig) async throws -> Void) async throws {
        let rig = Rig(turns: 40, size: size)
        defer { rig.close() }
        try await withKnownIssue("macOS 26 anchors the thread natively, and a short window still draws it blank there", isIntermittent: true) {
            try await rig.open()
            try await body(rig)
        } when: { ThreadTailAnchor.isNative && size.height < 900 }
    }

    /// Sending into a long thread: the echo and "Thinking…" arrive with pi running (two rows
    /// appended at once under a pinned view), the reply streams with tool calls between its
    /// paragraphs, and the turn finishes into its footer and "Edited N files" card.
    @Test(arguments: sizes)
    func aSendThenAStreamingTurnThenItsFinishNeverLeavesTheThreadBlank(size: CGSize) async throws {
        try await Self.withRig(size: size) { rig in
            let promptAt = Self.base + 41 * 60_000
            rig.store.draft = "Now refactor the thing and run the tests please."
            await rig.store.send()
            try await rig.expectTail("sending")
            await rig.publish { $0.append(Self.user("u40", "Now refactor the thing and run the tests please.", at: promptAt)) }
            try await rig.expectTail("the echo persisted with pi running")

            for k in 0..<6 {
                await rig.publish(provisional: [Self.streamingReply(1 + k / 2)])
                try await rig.expectTail("streaming text \(k)")
                await rig.publish(provisional: [Self.tool("r\(k)", "bash", ["command": "ls"], output: "", at: promptAt, status: "running", provisional: true)]) {
                    $0.append(Self.tool("n\(k)", k.isMultiple(of: 3) ? "edit" : "bash",
                                        k.isMultiple(of: 3) ? ["path": "Sources/Edit\(k).swift", "edits": [["oldText": "a", "newText": "a\nb\nc"]]] : ["command": "swift build"],
                                        output: (0..<(2 + k)).map { "line \($0)" }.joined(separator: "\n"), at: promptAt + Double(k) * 3000))
                }
                try await rig.expectTail("tool call \(k) done")
            }
            await rig.publish(running: false, turnChanges: [Self.recorded(promptAt: promptAt)]) {
                $0.append(Self.reply("a40", Self.prose(3, 40) + "\n\n" + Self.code(40), at: promptAt + 60_000))
            }
            try await rig.expectTail("the turn finishing")
            try await eventuallyOnMain("the turn to settle") { !rig.store.settledRunning }
            try await rig.expectTail("the turn settled")

            // And the next send, the way the reader does it after a finish.
            rig.store.draft = "Thanks. Now do the next step please."
            await rig.store.send()
            try await rig.expectTail("sending after the finish")
            await rig.publish(turnChanges: [Self.recorded(promptAt: promptAt)]) {
                $0.append(Self.user("u41", "Thanks. Now do the next step please.", at: promptAt + 120_000))
            }
            try await rig.expectTail("the second echo persisted")
            await rig.publish(provisional: [Self.streamingReply(1)], turnChanges: [Self.recorded(promptAt: promptAt)])
            try await rig.expectTail("the second reply streaming")
        }
    }

    /// Finishing while follow-ups wait in Up next: the tray collapses as the host delivers them,
    /// the turn settles into its footer, and a new turn starts, all in the same few frames.
    @Test(arguments: [1, 3])
    func aTurnFinishingWithFollowUpsWaitingInUpNextKeepsTheThreadDrawn(waiting: Int) async throws {
        try await Self.withRig(size: Self.sizes[0]) { rig in
            let promptAt = Self.base + 41 * 60_000
            await rig.publish { $0.append(Self.user("u40", "Refactor it.", at: promptAt)) }
            for k in 0..<4 {
                await rig.publish(provisional: [Self.streamingReply(1 + k)])
                try await rig.expectTail("streaming text \(k)")
            }

            // A steering row first, as Return makes it, then the queued ones.
            let texts = (0..<waiting).map { "Follow-up \($0): and then please also do this other thing." }
            await rig.publish(provisional: [Self.streamingReply(4)], queue: QueueFixture.messages(texts, steering: 1))
            try await eventuallyOnMain("Up next to hold the messages") { rig.store.queue.count == waiting }
            try await rig.expectTail("Up next growing")

            // The turn ends and the host hands pi the first message: the tray empties, the old turn
            // settles with its card, and a new user turn and its reply begin.
            await rig.publish(running: false, turnChanges: [Self.recorded(promptAt: promptAt)], queue: []) {
                $0.append(Self.reply("a40", Self.prose(3, 40) + "\n\n" + Self.code(40), at: promptAt + 60_000))
            }
            try await rig.expectTail("the turn finishing as the tray empties")
            await rig.publish(provisional: [Self.reply("provisional:assistant:2", "On it.", status: "streaming", at: promptAt + 62_000)],
                              turnChanges: [Self.recorded(promptAt: promptAt)], queue: []) {
                $0.append(Self.user("q0", texts[0], at: promptAt + 61_000))
            }
            try await rig.expectTail("the delivered message's turn starting")
        }
    }

    /// The model streams a tool call's arguments: its row exists at once (status streaming), is
    /// continued in place by the running call, and goes when the call never runs, so the live
    /// turn's rows change count and height while the tail is followed.
    @Test(arguments: sizes)
    func aToolCallStreamingRunningAndFinishingKeepsTheTail(size: CGSize) async throws {
        try await Self.withRig(size: size) { rig in
            let promptAt = Self.base + 41 * 60_000
            await rig.publish { $0.append(Self.user("u40", "Fix the flaky test.", at: promptAt)) }
            try await rig.expectTail("the prompt")

            func call(_ status: String, _ arguments: String) -> NativeThreadMessage {
                NativeThreadMessage(entryID: "provisional:tool:c1", role: "toolResult", blocks: [], toolName: "bash", toolCallID: "c1",
                                    argumentsText: arguments, status: status, truncated: false, startedAt: promptAt + 2000)
            }
            let command = #"{"command":"swift test --filter ThreadScrollingTests"}"#
            await rig.publish(provisional: [Self.streamingReply(2), call("streaming", #"{"command":"swift te"#)])
            try await rig.expectTail("the call's arguments streaming")
            await rig.publish(provisional: [Self.streamingReply(2), call("streaming", String(command.dropLast(6)))])
            try await rig.expectTail("more of the arguments")
            await rig.publish(provisional: [Self.streamingReply(2), call("running", command)])
            try await rig.expectTail("the call running in place")
            await rig.publish(provisional: [Self.streamingReply(3)]) {
                $0.append(Self.tool("c1", "bash", ["command": "swift test --filter ThreadScrollingTests"],
                                    output: (0..<14).map { "Test \($0) passed" }.joined(separator: "\n"), at: promptAt + 2000))
            }
            try await rig.expectTail("the call finished")
            // A second call whose row goes without ever running.
            await rig.publish(provisional: [Self.streamingReply(3), call("streaming", #"{"command":"rm"#)])
            try await rig.expectTail("another call streaming")
            await rig.publish(provisional: [Self.streamingReply(3)])
            try await rig.expectTail("that call's row removed")
            await rig.publish(running: false, turnChanges: [Self.recorded(promptAt: promptAt)]) {
                $0.append(Self.reply("a40", Self.prose(3, 40) + "\n\n" + Self.code(40), at: promptAt + 60_000))
            }
            try await rig.expectTail("the turn finishing")
        }
    }

    /// Steering interrupts the turn: pi stops (a "Stopped" note ends the reply) and the message
    /// that steered it starts a new turn straight after.
    @Test(arguments: sizes)
    func aSteerThatInterruptsTheTurnLeavesItsNoteAndTheNewTurnInView(size: CGSize) async throws {
        try await Self.withRig(size: size) { rig in
            let promptAt = Self.base + 41 * 60_000
            await rig.publish { $0.append(Self.user("u40", "Refactor it.", at: promptAt)) }
            await rig.publish(provisional: [Self.streamingReply(3)])
            try await rig.expectTail("the turn streaming")

            await rig.publish(running: false) {
                $0.append(Self.reply("a40", Self.prose(2, 40), status: "aborted", at: promptAt + 30_000))
            }
            try await rig.expectTail("the turn stopped")
            await rig.publish(provisional: [Self.streamingReply(1)]) {
                $0.append(Self.user("u41", "Stop, do this instead.", at: promptAt + 31_000))
            }
            try await rig.expectTail("the steering message's turn starting")
            await rig.publish(provisional: [Self.streamingReply(4)])
            try await rig.expectTail("its reply streaming")
            await rig.publish(running: false, turnChanges: [Self.recorded(promptAt: promptAt + 31_000)]) {
                $0.append(Self.reply("a41", Self.prose(3, 41) + "\n\n" + Self.code(41), at: promptAt + 90_000))
            }
            try await rig.expectTail("that turn finishing")
        }
    }
}

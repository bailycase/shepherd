import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The thread's and the composer's motion, recorded from a real `ThreadView` in an off-screen
/// window (DESIGN.md › Motion). Changes arrive the way the app's do: a snapshot the store pulls,
/// a command from the command center, a draft typed into the store. Nothing here clicks or
/// types.
///
/// "It moved" versus "it only faded" is read from where it draws: a fade never draws outside
/// the place it comes to rest, and a nudge on its way in does. Only the instant rules run on CI:
/// catching a motion mid-way depends on the machine (`.timingSensitive`).
@Suite("Thread motion", .serialized, .mainActorExclusive)
@MainActor
struct ThreadMotionTests {
    static let size = CGSize(width: 900, height: 800)

    // MARK: Turns

    /// A sent message rises into place from just below; under Reduce Motion it fades where it
    /// rests. (A thread short enough not to scroll, so only the bubble changes.)
    @Test(.timingSensitive, arguments: [false, true]) func aTurnThatArrivesRisesIntoPlaceUnlessReduceMotion(reduceMotion: Bool) async throws {
        let thread = MotionThread(Fixtures.snapshot(Fixtures.history(2)), reduceMotion: reduceMotion)
        defer { thread.close() }
        try await thread.waitUntilReady()
        // Through the right edge of the right-aligned bubble, above the composer.
        let column = CGRect(x: Self.size.width - AppLayout.threadGutter(width: Self.size.width) - 12, y: 0, width: 1, height: 560)

        let recording = await MotionProbe.record(thread.window, region: column) {
            thread.serve(Fixtures.snapshot(Fixtures.history(2) + [Fixtures.user("u2", "A brand new question")], revision: 2))
        }

        #expect(!recording.inBetween.isEmpty, "the bubble fades in over frames")
        // A fade never draws past where the bubble rests; rising from below, it does.
        let rest = try #require(recording.settled.lastRow(differingFrom: recording.before, by: Self.visible))
        let bottoms = recording.inBetween.compactMap { $0.lastRow(differingFrom: recording.before, by: Self.visible) }
        if reduceMotion {
            #expect(bottoms.allSatisfy { $0 <= rest + 1 }, "it fades where it rests: \(bottoms), resting at \(rest)")
        } else {
            #expect(bottoms.contains { $0 > rest + 2 }, "it starts below its place: \(bottoms), resting at \(rest)")
        }
    }

    /// A sent message brightens in place once pi has it (70% → 100%), and a queued follow-up
    /// turns into a sent one in place when its turn ends. The bubble is one view throughout
    /// (the echo and the saved message have different entries): its fill eases from its first
    /// look to its last instead of being swapped for a new bubble.
    @Test(.timingSensitive, arguments: [false, true]) func aSentMessageSettlesInPlace(queued: Bool) async throws {
        let text = "Then open the PR against nightly."
        let thread = MotionThread(Fixtures.snapshot(Fixtures.history(2), running: queued))
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = text
        await thread.store.send()
        try await eventuallyOnMain("the echo") { thread.store.pending.first?.status == (queued ? "queued" : "pending") }
        try await thread.settle()
        // Through the bubble's fill, right of its text.
        let column = CGRect(x: Self.size.width - AppLayout.threadGutter(width: Self.size.width) - 12, y: 0, width: 1, height: 560)

        let recording = await MotionProbe.record(thread.window, region: column) {
            thread.serve(Fixtures.snapshot(Fixtures.history(2) + [Fixtures.user("u2", text)], revision: 2))
        }

        // The sent bubble's middle row: its fill, between its top and bottom lines (the rows that
        // changed and are drawn on).
        let settled = recording.settled
        let bubble = (0..<settled.bitmap.pixelsHigh).filter {
            settled.lightness(x: 0, y: $0) < 0.975 && settled.lightness(x: 0, y: $0) != recording.before.lightness(x: 0, y: $0)
        }
        let resting = try #require(bubble.isEmpty ? nil : (bubble.first! + bubble.last!) / 2, "the sent bubble")
        // A queued follow-up sits under the reply that was running, which takes its footer's
        // place as it ends: the bubble moves down by it, so each frame is read at the bubble's
        // own middle there (the lowest run of rows off the background, right of the prose).
        let background = settled.lightness(x: 0, y: min(bubble.last! + 20, settled.bitmap.pixelsHigh - 1))
        func middle(_ frame: MotionRecording.Frame) -> Int {
            let rows = (0..<frame.bitmap.pixelsHigh).filter { abs(frame.lightness(x: 0, y: $0) - background) > 0.004 }
            guard var top = rows.last, let bottom = rows.last else { return resting }
            let set = Set(rows)
            while set.contains(top - 1) { top -= 1 }
            return (top + bottom) / 2
        }
        let first = recording.before.lightness(x: 0, y: middle(recording.before)), last = settled.lightness(x: 0, y: resting)
        let path = recording.inBetween.map { $0.lightness(x: 0, y: middle($0)) }
        #expect(abs(first - last) > 0.01, "the bubble's fill changed")
        #expect(path.contains { abs($0 - first) < abs($0 - last) && abs($0 - first) > 0.001 },
                "it eases from \(first) to \(last): \(path)")
    }

    /// A lightness difference a reader would see.
    static let visible = 0.03

    // MARK: Switching

    /// Entrances counted (`nwArrival`) while `work` runs.
    private func entrances(_ work: () async throws -> Void) async rethrows -> Int {
        NWRenderProbe.start()
        try await work()
        return NWRenderProbe.stop()["arrival.animates", default: 0]
    }

    /// Switching back to an agent is a flip: the turns its thread catches up on, which arrived
    /// while it was hidden, are simply there.
    @Test func nothingMakesAnEntranceOnASwitch() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(4)), dark: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await thread.show(false)
        thread.snapshot = ThreadFixture.snapshot(ThreadFixture.history(4) + [ThreadFixture.user("u9", "Asked while you were away"),
                                                                             ThreadFixture.assistant("a9", "Answered.")], revision: 2)

        let count = try await entrances { try await thread.show(true) }

        #expect(thread.store.rows.count == 6, "the thread caught up")
        #expect(count == 0)
    }

    /// Caught up, the thread's motion is back: a turn that arrives after switching back rises in.
    @Test func aTurnAfterSwitchingBackMakesItsEntrance() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(4)), dark: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await thread.show(false)
        try await thread.show(true)

        let count = await entrances {
            await thread.serve(ThreadFixture.snapshot(ThreadFixture.history(4) + [ThreadFixture.user("u9", "One more thing")], revision: 2))
            ListPerf.settle(thread.window)
        }

        #expect(count > 0)
    }

    /// Text streaming into a reply appears at once: no row, part, or line animates per chunk.
    @Test func streamedTextAppearsAtOnce() async throws {
        let first = "Streaming a reply that keeps growing."
        let thread = MotionThread(Fixtures.snapshot(Fixtures.history(2) + [Fixtures.user("u2", "Go")],
                                                    provisional: [Fixtures.streaming(first)], running: true))
        defer { thread.close() }
        try await thread.waitUntilReady()
        // Through the prose.
        let column = CGRect(x: 300, y: 0, width: 1, height: 560)

        let recording = await MotionProbe.record(thread.window, region: column) {
            let longer = first + " " + Array(repeating: "More words arrive in the next chunk of the stream.", count: 8).joined(separator: " ")
            thread.serve(Fixtures.snapshot(Fixtures.history(2) + [Fixtures.user("u2", "Go")],
                                           provisional: [Fixtures.streaming(longer)], running: true, revision: 2))
        }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the text grew")
        #expect(recording.inBetween.isEmpty, "\(recording.inBetween.count) frames between the chunk and the text")
    }

    /// A running call that ends cross-fades into its finished line in place, and its output lines
    /// go at once.
    @Test(.timingSensitive) func aLiveLineSettlesIntoItsFinishedLine() async throws {
        let turn = Fixtures.history(2) + [Fixtures.user("u2", "Build it"), Fixtures.assistant("a2", "Building now.")]
        let live = Fixtures.snapshot(turn, provisional: [Fixtures.bash(status: "running")], running: true)
        let finished = Fixtures.snapshot(turn + [Fixtures.bash(status: "complete")], running: true, revision: 2)
        let thread = MotionThread(live)
        defer { thread.close() }
        try await thread.waitUntilReady()
        // From the bottom: the three output lines, then the line itself. Nothing sits under a
        // live line (LiveText).
        let lines = thread.textRows()
        try #require(lines.count >= 4, "rows of text: \(lines)")
        let header = lines[lines.count - 4], lastOutput = lines[lines.count - 1]

        // Clear of the glyph at the start of the line.
        let headerRecording = await MotionProbe.record(thread.window, region: CGRect(x: 60, y: header, width: 400, height: 1)) {
            thread.serve(finished)
        }
        #expect(!headerRecording.inBetween.isEmpty, "the line cross-fades into its finished words")

        // Again from the start, watching the last output line.
        let again = MotionThread(live)
        defer { again.close() }
        try await again.waitUntilReady()
        let outputRecording = await MotionProbe.record(again.window, region: CGRect(x: 60, y: lastOutput, width: 400, height: 1)) {
            again.serve(finished)
        }
        #expect(outputRecording.settled.firstColumn(differingFrom: outputRecording.before) != nil, "the output lines went")
        #expect(outputRecording.inBetween.isEmpty, "the output lines go at once")
    }

    /// When a turn ends its reply stays exactly as it streamed (the saved copy is the same view,
    /// part for part), and its footer takes its place beneath out of sight: it shows only while
    /// the turn is hovered (`ThreadHoverTests` watches it rise in under the pointer).
    @Test(.timingSensitive) func aTurnThatEndsKeepsItsReplyStillAndItsFooterOutOfSight() async throws {
        let asked = 1_700_000_000_000.0
        let prompt = NativeThreadMessage(entryID: "u2", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Answer me")],
                                         truncated: false, timestamp: asked)
        let text = "Here is the answer, streamed in full before the turn ends."
        let turn = Fixtures.history(2) + [prompt]
        let thread = MotionThread(Fixtures.snapshot(turn, provisional: [Fixtures.streaming(text)], running: true))
        defer { thread.close() }
        try await thread.waitUntilReady()
        // From the bottom: the reply's one line of prose, the thread's live indicator while it
        // is written (LiveText).
        let lines = thread.textRows()
        try #require(lines.count >= 1, "rows of text: \(lines)")
        let prose = Int(lines[lines.count - 1])
        let saved = NativeThreadMessage(entryID: "a2", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)],
                                        truncated: false, timestamp: asked + 5000)
        // The prose and, below it, where the footer's time ("4:13 PM · 5s") would be, clear of the
        // footer's buttons.
        let column = CGRect(x: AppLayout.threadGutter(width: Self.size.width) + 90, y: CGFloat(prose - 8), width: 210, height: 64)

        let recording = await MotionProbe.record(thread.window, region: column, timeout: 1) {
            thread.serve(Fixtures.snapshot(turn + [saved], revision: 2))
        }

        try await eventuallyOnMain("the turn to end") { thread.store.rows.last?.live == false }
        let ended = await MotionProbe.record(thread.window, region: column, timeout: 0.3) {}
        let frames = recording.frames + ended.frames

        let proseRows = 0..<16
        #expect(frames.allSatisfy { frame in !proseRows.contains { frame.differs(from: recording.before, row: $0) } },
                "the reply never redrew")
        #expect(frames.allSatisfy { $0.lastRow(differingFrom: recording.before, by: Self.visible) == nil },
                "nothing shows beneath it until the turn is hovered")
    }

    private static let asked = Fixtures.history(2) + [Fixtures.user("u2", "Build it")]

    /// What an agent did while hidden: the reply it was streaming finished, new turns, and a
    /// question waiting in the composer.
    private static let caughtUp = Fixtures.snapshot(
        asked + [Fixtures.assistant("a2", "Building now, and done."), Fixtures.user("u3", "And then?"),
                 Fixtures.assistant("a3", "Done while hidden, with a reply long enough to read.")],
        dialogs: [NativeThreadDialog(id: "d1", kind: .confirm, title: "Deploy to production?", message: "This pushes main to the fleet.")],
        revision: 2)

    /// Switching back to an agent is a visibility flip: what it did while hidden (the reply it
    /// was streaming finished, new turns, a question waiting in the composer, Retry back on
    /// old turns) is simply there once its thread catches up, while the same changes on screen
    /// make their entrances.
    @Test func anAgentSwitchedBackToCatchesUpAtOnce() async throws {
        let thread = MotionThread(Fixtures.snapshot(Self.asked, provisional: [Fixtures.streaming("Building now")], running: true))
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.visibility.active = false
        try await eventuallyOnMain("the hidden thread to stop polling") { thread.store.catchUp == nil }
        // Hidden, it keeps what it showed (still running): the pull that catches it up turns
        // Stop back into Send with everything else.
        try await thread.settle(whole: true)
        thread.stage(Self.caughtUp)

        let recording = await MotionProbe.record(thread.window) { thread.visibility.active = true }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the thread caught up")
        #expect(recording.inBetween.isEmpty, "\(recording.inBetween.count) frames between the stale thread and the caught-up one")
    }

    /// The control: on screen, the same changes make their entrances, so the check above is not
    /// vacuous.
    @Test(.timingSensitive) func theSameChangesOnScreenAnimate() async throws {
        let shown = MotionThread(Fixtures.snapshot(Fixtures.history(2)))
        defer { shown.close() }
        try await shown.waitUntilReady()
        let onScreen = await MotionProbe.record(shown.window) { shown.serve(Self.caughtUp) }
        #expect(!onScreen.inBetween.isEmpty)
    }

    /// A paused queue of one above the composer, and the same queue with two more messages.
    private static let queued = QueueFixture.messages(["Then run the tests"])
    private static func queueSnapshot(_ items: [NativeQueuedMessage], revision: UInt64) -> NativeThreadSnapshot {
        var snapshot = Fixtures.snapshot(Self.asked + [Fixtures.assistant("a2", "Stopped before the build.")], revision: revision)
        snapshot.queue = NativeQueue(items: items, mode: .all, paused: true)
        snapshot.supportedActions.append("queue")
        return snapshot
    }
    private static let grownQueue = queueSnapshot(queued + QueueFixture.messages(["And lint it", "Then open the PR"]), revision: 2)

    /// Messages another client queued while the agent was hidden are simply there when its
    /// thread catches up, like everything else in the composer: the queue alone changed.
    @Test func aQueueThatChangedWhileHiddenIsThereAtOnce() async throws {
        let thread = MotionThread(Self.queueSnapshot(Self.queued, revision: 1))
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.visibility.active = false
        try await eventuallyOnMain("the hidden thread to stop polling") { thread.store.catchUp == nil }
        try await thread.settle(whole: true)
        thread.stage(Self.grownQueue)

        let recording = await MotionProbe.record(thread.window) { thread.visibility.active = true }

        #expect(thread.store.queue.count == 3)
        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the queue caught up")
        #expect(recording.inBetween.isEmpty, "\(recording.inBetween.count) frames between the stale queue and the caught-up one")
    }

    /// The control: on screen, the same messages join the stack over frames.
    @Test(.timingSensitive) func theSameQueueChangeOnScreenAnimates() async throws {
        let shown = MotionThread(Self.queueSnapshot(Self.queued, revision: 1))
        defer { shown.close() }
        try await shown.waitUntilReady()
        let onScreen = await MotionProbe.record(shown.window) { shown.serve(Self.grownQueue) }
        #expect(!onScreen.inBetween.isEmpty)
    }

    /// Detaching from the tail while pi runs brings "Jump to latest" in over frames (growing from
    /// above the composer, or under Reduce Motion fading), whatever the rows beside it do.
    @Test(.timingSensitive, arguments: [false, true]) func theJumpPillComesInAsTheThreadDetaches(reduceMotion: Bool) async throws {
        let size = CGSize(width: 900, height: 600)
        let long = (0..<24).map { i in
            i % 2 == 0 ? Fixtures.user("m\(i)", "Question \(i)")
                : Fixtures.assistant("m\(i)", Array(repeating: "Answer \(i) with enough words to wrap a line or two in the column.",
                                                    count: 20).joined(separator: "\n\n"))
        }
        // Running: with pi idle and nothing new below, a detached thread shows no pill.
        let thread = MotionThread(Fixtures.snapshot(long, running: true), reduceMotion: reduceMotion, size: size)
        defer { thread.close() }
        try await thread.waitUntilReady()
        // Well above the tail first (not the reader: still following), so the jump lands clear of it.
        thread.scroll(toDistance: 900)
        try await thread.settle()
        // Right of the column's text, through the pill's end, above the composer.
        let pill = CGRect(x: size.width / 2 + 55, y: 440, width: 1, height: 64)

        let recording = await MotionProbe.record(thread.window, region: pill) { thread.commands.send(.previousTurn, to: "motion") }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the pill came")
        #expect(!recording.inBetween.isEmpty, "it came in over frames")
        // The pill is at rest before the jump behind it lands: let it land before the window
        // goes, so no scroll is still animating when the next test starts.
        try await thread.settle()
    }

    // MARK: Composer

    /// ⇧⌘M's picker comes in over frames (growing from the chip's corner, or under Reduce Motion
    /// fading: `NW.Motion.overlay`'s transitions, pinned in MotionTests) and closes the same way.
    /// A fresh thread, so nothing but the picker changes above the card.
    @Test(.timingSensitive, arguments: [false, true]) func theModelPickerComesAndGoesWithMotion(reduceMotion: Bool) async throws {
        let thread = MotionThread(Fixtures.snapshot([]), reduceMotion: reduceMotion)
        defer { thread.close() }
        try await thread.waitUntilReady()
        // Through the model names, above the card.
        let column = CGRect(x: AppLayout.threadGutter(width: Self.size.width) + 60, y: 300, width: 1, height: 380)

        let opening = await MotionProbe.record(thread.window, region: column) { thread.commands.send(.modelPicker, to: "motion") }
        #expect(opening.settled.firstRow(differingFrom: opening.before) != nil, "the picker opened")
        #expect(!opening.inBetween.isEmpty, "it came in over frames")

        let closing = await MotionProbe.record(thread.window, region: column) { thread.commands.send(.modelPicker, to: "motion") }
        #expect(closing.settled.matches(opening.before), "the picker closed")
        #expect(!closing.inBetween.isEmpty, "it went over frames")
    }

    /// Starting a draft with "/" grows the command menu in over frames, and clearing it takes
    /// the menu away the same way: the typing path, beside ⇧⌘M's.
    @Test(.timingSensitive) func theSlashMenuComesAndGoesWithTheDraftsSlash() async throws {
        let thread = MotionThread(Fixtures.snapshot([]))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let column = CGRect(x: AppLayout.threadGutter(width: Self.size.width) + 60, y: 300, width: 1, height: 380)

        let opening = await MotionProbe.record(thread.window, region: column) { thread.store.draft = "/" }
        #expect(opening.settled.firstRow(differingFrom: opening.before) != nil, "the menu opened")
        #expect(!opening.inBetween.isEmpty, "it came in over frames")

        let closing = await MotionProbe.record(thread.window, region: column) { thread.store.draft = "" }
        #expect(closing.settled.matches(opening.before), "the menu closed")
        #expect(!closing.inBetween.isEmpty, "it went over frames")
    }

    /// Filtering the slash menu as the draft grows is typing: the list changes at once.
    @Test(.timingSensitive) func filteringTheSlashMenuIsInstant() async throws {
        let thread = MotionThread(Fixtures.snapshot([]))
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = "/"
        try await thread.settle()
        let column = CGRect(x: AppLayout.threadGutter(width: Self.size.width) + 60, y: 300, width: 1, height: 380)

        // Three commands match "/", one matches "/rev": the menu shrinks to one row.
        let recording = await MotionProbe.record(thread.window, region: column) { thread.store.draft = "/rev" }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the menu filtered")
        #expect(recording.inBetween.isEmpty)
    }

    /// A question takes the field's place: the card grows upward over frames while its control
    /// row stays exactly where it was.
    @Test(.timingSensitive) func aQuestionGrowsTheCardUpwardWhileItsControlsStayPut() async throws {
        let thread = MotionThread(Fixtures.snapshot([]))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let column = CGRect(x: AppLayout.threadGutter(width: Self.size.width) + 40, y: 300, width: 1, height: Self.size.height - 300)
        let dialog = NativeThreadDialog(id: "d1", kind: .confirm, title: "Deploy to production?", message: "This pushes main to the fleet.")

        let recording = await MotionProbe.record(thread.window, region: column) {
            thread.serve(Fixtures.snapshot([], dialogs: [dialog], revision: 2))
        }

        // The fade over the card sits a level off the window's background: read the card's edge
        // by a visible difference.
        let top = try #require(recording.settled.firstRow(differingFrom: recording.before, by: 0.02), "the card grew")
        let bottom = try #require(recording.settled.lastRow(differingFrom: recording.before))
        let tops = recording.inBetween.compactMap { $0.firstRow(differingFrom: recording.before, by: 0.02) }
        #expect(tops.contains { $0 > top + 4 }, "caught growing: \(tops) toward \(top)")
        let bottoms = recording.frames.compactMap { $0.lastRow(differingFrom: recording.before) }
        #expect(bottoms.allSatisfy { $0 <= bottom }, "nothing below the field moved: \(bottoms), field ends at \(bottom)")
    }

    /// Send and Stop are one button: when a turn starts, the glyph and the fill blend in place
    /// and the circle never moves or resizes.
    @Test(.timingSensitive) func sendTurnsIntoStopInPlace() async throws {
        let thread = MotionThread(Fixtures.snapshot(Fixtures.history(2)))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let center = Self.size.height - AppLayout.composerBottom - NW.Space.s - NWComposerMetrics.actionSize / 2
        let strip = CGRect(x: Self.size.width - 120, y: center, width: 120, height: 1)

        let recording = await MotionProbe.record(thread.window, region: strip, timeout: 1.5) {
            thread.serve(Fixtures.snapshot(Fixtures.history(2), running: true, revision: 2))
        }

        #expect(!recording.inBetween.isEmpty, "the fill and glyph blend over frames")
        // The strip starts on the card's fill: the first pixel unlike it is the circle's edge.
        let card = recording.before.blank
        let edges = recording.frames.compactMap { $0.firstColumn(differingFrom: card) }
        #expect((edges.max() ?? 0) - (edges.min() ?? 0) <= 1, "the circle holds its place and size: \(Set(edges))")
    }

    /// Typing a longer draft grows the field at once: keyboard input never animates.
    @Test(.timingSensitive) func typingGrowsTheFieldAtOnce() async throws {
        let thread = MotionThread(Fixtures.snapshot(Fixtures.history(2)))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let column = CGRect(x: AppLayout.threadGutter(width: Self.size.width) + 40, y: 400, width: 1, height: Self.size.height - 400)

        let recording = await MotionProbe.record(thread.window, region: column) {
            thread.store.draft = (1...4).map { "line \($0)" }.joined(separator: "\n")
        }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the field grew")
        #expect(recording.inBetween.isEmpty)
    }
}

// MARK: Components

/// The thread's motion primitives on stand-ins (a black bar on white, as in MotionProbeTests),
/// and thinking's disclosure.
@Suite("Thread component motion", .serialized, .mainActorExclusive, .timingSensitive)
@MainActor
struct ThreadComponentMotionTests {
    @MainActor @Observable
    final class Toggle {
        var on = false
    }

    /// A 100×20 black bar in the middle of a white strip, shown while `toggle.on`.
    private struct Bar<Motion: ViewModifier>: View {
        let toggle: Toggle
        let motion: Motion
        var animated = false

        var body: some View {
            ZStack {
                Color.white
                if toggle.on { Color.black.frame(width: 100, height: 20).modifier(motion) }
            }
            .frame(width: 300, height: 60)
            .nwAnimation(.content, value: animated ? toggle.on : false)
        }
    }

    private struct Arrival: ViewModifier {
        let isNew: Bool
        func body(content: Content) -> some View { content.nwArrival(isNew, .list, edge: .bottom) }
    }

    private struct Entrance: ViewModifier {
        func body(content: Content) -> some View { content.nwEntrance(.content) }
    }

    /// Through the bar.
    private let column = CGRect(x: 150, y: 0, width: 1, height: 60)

    private func window(_ view: some View, reduceMotion: Bool = false) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 300, height: 60), dark: false, view.environment(\._accessibilityReduceMotion, reduceMotion))
    }

    /// Waits until the window draws the same picture for a few polls, so work queued on the main
    /// thread (an earlier test's windows going away) is done before a recording starts: a stall
    /// in a motion's first frames would hide where it starts.
    private func atRest(_ window: OffscreenWindow) async throws {
        var last = 0, still = 0
        try await eventuallyOnMain("the window to come to rest", timeout: .seconds(10), poll: .milliseconds(20)) {
            window.layout()
            let host = window.host
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds), let data = bitmap.bitmapData else { return false }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let hash = Data(bytes: data, count: bitmap.bytesPerPlane).hashValue
            still = hash == last ? still + 1 : 0
            last = hash
            return still >= 5
        }
    }

    /// A row that streams in rises from just below its place as it fades in, in a plain
    /// transaction (the store's); under Reduce Motion it only fades.
    @Test(arguments: [false, true]) func anArrivalRisesIntoPlaceUnlessReduceMotion(reduceMotion: Bool) async throws {
        let toggle = Toggle()
        let window = window(Bar(toggle: toggle, motion: Arrival(isNew: true)), reduceMotion: reduceMotion)
        defer { window.close() }
        try await atRest(window)

        let recording = await MotionProbe.record(window, region: column) { toggle.on = true }

        let rest = try #require(recording.settled.lastRow(differingFrom: recording.before))
        let bottoms = recording.inBetween.compactMap { $0.lastRow(differingFrom: recording.before) }
        #expect(!bottoms.isEmpty, "caught arriving in \(recording.frames.count) frames")
        if reduceMotion {
            #expect(bottoms.allSatisfy { $0 == rest }, "it fades where it rests: \(bottoms)")
            #expect(recording.inBetween.contains { (0.05..<0.95).contains($0.lightness(x: 0, y: rest - 5)) }, "it fades in")
        } else {
            #expect(bottoms.contains { $0 > rest + 2 }, "it starts below its place: \(bottoms), resting at \(rest)")
            #expect(bottoms.allSatisfy { $0 >= rest && $0 <= rest + Int(NW.Motion.nudge) }, "a nudge, no more: \(bottoms)")
        }
    }

    /// A row that loads with the thread, or scrolls back into a lazy stack, is simply there.
    @Test func aViewThatIsNotNewNeverArrives() async throws {
        let toggle = Toggle()
        let window = window(Bar(toggle: toggle, motion: Arrival(isNew: false)))
        defer { window.close() }
        try await atRest(window)

        let recording = await MotionProbe.record(window, region: column) { toggle.on = true }

        #expect(recording.settled.lastRow(differingFrom: recording.before) != nil)
        #expect(recording.inBetween.isEmpty)
    }

    /// The composer's field and a question: what arrives fades in, what leaves goes at once.
    @Test func anEntranceFadesInAndLeavesAtOnce() async throws {
        let toggle = Toggle()
        let window = window(Bar(toggle: toggle, motion: Entrance(), animated: true))
        defer { window.close() }
        try await atRest(window)

        let arriving = await MotionProbe.record(window, region: column) { toggle.on = true }
        #expect(!arriving.inBetween.isEmpty, "it fades in")
        let leaving = await MotionProbe.record(window, region: column) { toggle.on = false }
        #expect(leaving.settled.matches(arriving.before), "it left")
        #expect(leaving.inBetween.isEmpty, "at once")
    }

    private struct Thinking: View {
        let toggle: Toggle

        var body: some View {
            NWThinking("Thought for 4s", text: "Where do the labels render? The desktop thread view and the iOS bubble both draw them.",
                       isExpanded: Binding(get: { toggle.on }, set: { toggle.on = $0 }))
                .frame(width: 400, height: 120, alignment: .topLeading)
                .padding(20)
                .background(Color.nw.bgWindow)
        }
    }

    /// Expanding thinking eases its text in from above; under Reduce Motion the text fades in
    /// place. The change runs the way the disclosure's own button runs it.
    @Test(arguments: [false, true]) func thinkingOpensDownwardUnlessReduceMotion(reduceMotion: Bool) async throws {
        let toggle = Toggle()
        let window = OffscreenWindow(size: CGSize(width: 440, height: 160), dark: false,
                                     Thinking(toggle: toggle).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        // Through the text, clear of the chevron and the title.
        let column = CGRect(x: 200, y: 40, width: 1, height: 110)
        try await atRest(window)

        let recording = await MotionProbe.record(window, region: column) {
            withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) { toggle.on = true }
        }

        #expect(!recording.inBetween.isEmpty)
        // A fade never draws above where the text rests; nudging down from above, it does.
        let rest = try #require(recording.settled.firstRow(differingFrom: recording.before, by: ThreadMotionTests.visible))
        let tops = recording.inBetween.compactMap { $0.firstRow(differingFrom: recording.before, by: ThreadMotionTests.visible) }
        if reduceMotion {
            #expect(tops.allSatisfy { $0 >= rest - 1 }, "it fades where it rests: \(tops), resting at \(rest)")
        } else {
            #expect(tops.contains { $0 < rest - 2 }, "it starts above its place: \(tops), resting at \(rest)")
        }
    }

    /// Thinking's chevron turns to point down as it opens; under Reduce Motion nothing turns,
    /// and its two positions cross-fade. A fade only ever draws between its two ends: no pixel
    /// on the way is darker or lighter than both.
    @Test(arguments: [false, true]) func theChevronTurnsUnlessReduceMotion(reduceMotion: Bool) async throws {
        let toggle = Toggle()
        let window = OffscreenWindow(size: CGSize(width: 440, height: 160), dark: false,
                                     Thinking(toggle: toggle).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        // Around the chevron, above the thinking text.
        let chevron = CGRect(x: 16, y: 18, width: 18, height: 18)
        try await atRest(window)

        let recording = await MotionProbe.record(window, region: chevron) {
            withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) { toggle.on = true }
        }

        #expect(!recording.inBetween.isEmpty, "the chevron changes over frames")
        let outside = recording.inBetween.map { $0.pixelsOutside(recording.before, recording.settled) }
        if reduceMotion {
            #expect(outside.allSatisfy { $0 == 0 }, "it only fades: \(outside) pixels past both ends")
        } else {
            #expect(outside.contains { $0 > 0 }, "it turns through positions neither end has")
        }
    }
}

// MARK: Harness

/// A `ThreadView` in an off-screen window, served snapshots the test sets.
@MainActor
private final class MotionThread {
    /// Whether the thread is on screen: a hidden agent's thread stops polling.
    @MainActor @Observable final class Visibility {
        var active = true
    }

    private struct Hosted: View {
        let visibility: Visibility
        let store: NativeThreadStore
        let request: NativeThreadStore.Request
        let models: [PiModelCatalog.Entry]

        var body: some View {
            ThreadView(store: store, active: visibility.active, isFocused: false, request: request, commandKey: "motion",
                       listModels: { ModelCatalog(models) })
        }
    }

    let store = NativeThreadStore()
    let commands = ThreadCommandCenter()
    let visibility = Visibility()
    private var snapshot: NativeThreadSnapshot
    let window: OffscreenWindow

    init(_ snapshot: NativeThreadSnapshot, reduceMotion: Bool = false, size: CGSize = ThreadMotionTests.size) {
        self.snapshot = snapshot
        window = OffscreenWindow(size: size, dark: false)
        let request: NativeThreadStore.Request = { [weak self] value in
            guard let self else { return .failure(code: "gone", message: "harness released") }
            if case .send(_, _, let operation, _, _, _) = value { return .accepted(operationID: operation) }
            return .snapshot(value: self.snapshot)
        }
        window.show(Hosted(visibility: visibility, store: store, request: request, models: Fixtures.models)
            .environment(\.threadCommands, commands)
            .environment(\._accessibilityReduceMotion, reduceMotion))
    }

    /// Serves `next` and has the store pull it now, outside any animation, as a poll would.
    func serve(_ next: NativeThreadSnapshot) {
        snapshot = next
        Task { await store.refresh() }
    }

    /// Serves `next` on the store's next pull, without pulling.
    func stage(_ next: NativeThreadSnapshot) {
        snapshot = next
    }

    func waitUntilReady() async throws {
        try await eventuallyOnMain("the thread to load") { store.ready }
        try await settle()
    }

    /// Waits until the window stops changing (loading, first layout, arrivals). By default it
    /// watches a band clear of running spinners; `whole` watches everything (a thread with none).
    func settle(whole: Bool = false) async throws {
        let band = whole ? CGRect(origin: .zero, size: window.host.bounds.size)
            : CGRect(x: 60, y: 0, width: 240, height: ThreadMotionTests.size.height)
        var last = snapshotHash(band), still = 0
        try await eventuallyOnMain("the thread to come to rest", timeout: .seconds(10), poll: .milliseconds(20)) {
            let now = snapshotHash(band)
            still = now == last ? still + 1 : 0
            last = now
            return still >= 6
        }
    }

    /// The middle row of each line of text in the thread's left half above the composer, top to
    /// bottom (right-aligned bubbles fall outside it).
    func textRows() -> [CGFloat] {
        let gutter = AppLayout.threadGutter(width: ThreadMotionTests.size.width)
        let band = CGRect(x: gutter, y: 0, width: 300, height: ThreadMotionTests.size.height - 160)
        let frame = capture(band)
        var rows: [CGFloat] = []
        var start: Int?
        for y in 0...frame.bitmap.pixelsHigh {
            let ink = y < frame.bitmap.pixelsHigh && (0..<frame.bitmap.pixelsWide).contains { frame.lightness(x: $0, y: y) < 0.8 }
            if ink, start == nil { start = y }
            if !ink, let first = start {
                rows.append(CGFloat(first + (y - first) / 2))
                start = nil
            }
        }
        return rows
    }

    func close() {
        store.stop()
        window.close()
    }

    /// Scrolls the clip view so the visible bottom sits `distance` above the end, as a program
    /// would (not the reader: following is unchanged).
    func scroll(toDistance distance: CGFloat) {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let scrollView = find(window.host), let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let y = document.bounds.height - clip.bounds.height + scrollView.contentInsets.bottom - distance
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        window.layout()
    }

    private func snapshotHash(_ band: CGRect) -> Int {
        let frame = capture(band)
        guard let data = frame.bitmap.bitmapData else { return 0 }
        return Data(bytes: data, count: frame.bitmap.bytesPerPlane).hashValue
    }

    private func capture(_ rect: CGRect) -> MotionRecording.Frame {
        window.layout()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                      bitsPerPixel: 0)!
        bitmap.size = rect.size
        window.host.cacheDisplay(in: rect, to: bitmap)
        return MotionRecording.Frame(time: 0, bitmap: bitmap)
    }
}

private enum Fixtures {
    static let models = [("anthropic/claude-opus-4-5", "200K"), ("anthropic/claude-haiku-4-5", "200K"), ("openai/gpt-5", "400K")]
        .map { PiModelCatalog.Entry(id: $0.0, context: $0.1) }

    static func user(_ id: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
    }

    static func assistant(_ id: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
    }

    static func streaming(_ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)],
                            status: "streaming", truncated: false)
    }

    /// A build with three output lines; untimed, so no elapsed clock ticks while recording.
    static func bash(status: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "t-b1", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "Compiling A\nCompiling B\nLinking")],
                            toolName: "bash", toolCallID: "b1", argumentsText: "{\"command\":\"swift build\"}", status: status, truncated: false)
    }

    static func history(_ count: Int) -> [NativeThreadMessage] {
        (0..<count).map { i in i % 2 == 0 ? user("m\(i)", "Question \(i)") : assistant("m\(i)", "Answer \(i).") }
    }

    static func snapshot(_ messages: [NativeThreadMessage], provisional: [NativeThreadMessage] = [], running: Bool = false,
                         dialogs: [NativeThreadDialog] = [], revision: UInt64 = 1) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: running, model: "anthropic/claude-opus-4-5",
                             thinking: "medium", supportedActions: ["send", "abort", "answer", "setModel", "setThinking"],
                             dialogsSupported: true, dialogs: dialogs, messages: messages, provisional: provisional, clipped: false,
                             commands: [NativeCommand(name: "review", description: "Review the working tree", source: "prompt"),
                                        NativeCommand(name: "reload", description: "Reload extensions", source: "extension"),
                                        NativeCommand(name: "resume", description: "Resume a session", source: "extension")])
    }
}

// MARK: Reading frames

extension MotionRecording.Frame {
    /// This frame's own background: every pixel the color of its first one.
    fileprivate var blank: MotionRecording.Frame {
        let copy = bitmap.copy() as! NSBitmapImageRep
        let first = copy.colorAt(x: 0, y: 0) ?? .white
        for x in 0..<copy.pixelsWide { for y in 0..<copy.pixelsHigh { copy.setColor(first, atX: x, y: y) } }
        return MotionRecording.Frame(time: time, bitmap: copy)
    }

    /// The first row, from the top, where this frame's lightness is more than `threshold` from
    /// `other`'s: faint edges (a shadow, a fade a level off the background) don't count.
    fileprivate func firstRow(differingFrom other: MotionRecording.Frame, by threshold: Double) -> Int? {
        (0..<bitmap.pixelsHigh).first { differs(from: other, row: $0, by: threshold) }
    }

    /// The last row where this frame's lightness is more than `threshold` from `other`'s.
    fileprivate func lastRow(differingFrom other: MotionRecording.Frame, by threshold: Double) -> Int? {
        (0..<bitmap.pixelsHigh).reversed().first { differs(from: other, row: $0, by: threshold) }
    }

    /// How many pixels are darker or lighter than both `a` and `b` (by more than a rounding
    /// step): a cross-fade between them never has any.
    fileprivate func pixelsOutside(_ a: MotionRecording.Frame, _ b: MotionRecording.Frame) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let value = lightness(x: x, y: y), first = a.lightness(x: x, y: y), second = b.lightness(x: x, y: y)
                if value < min(first, second) - 0.02 || value > max(first, second) + 0.02 { count += 1 }
            }
        }
        return count
    }

    /// Whether any pixel of row `y` differs from `other` at all.
    fileprivate func differs(from other: MotionRecording.Frame, row y: Int) -> Bool {
        (0..<bitmap.pixelsWide).contains { x in lightness(x: x, y: y) != other.lightness(x: x, y: y) }
    }

    private func differs(from other: MotionRecording.Frame, row y: Int, by threshold: Double) -> Bool {
        (0..<bitmap.pixelsWide).contains { x in abs(lightness(x: x, y: y) - other.lightness(x: x, y: y)) > threshold }
    }
}

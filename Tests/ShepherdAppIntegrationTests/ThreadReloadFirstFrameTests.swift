import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote

/// A thread that fell out of the history bounds (`NativeThreadStores`) and comes back draws its tail in its first frame, from what
/// it kept: no pull has returned, nothing is parsed, and the pull that lands after it neither moves the reader nor builds a row again.
@Suite("Thread reload first frame", .mainActorExclusive)
@MainActor
struct ThreadReloadFirstFrameTests {
    private static let session = ThreadFixture.history(240)

    /// A thread on screen that holds more than the newest page (it paged older history in).
    private func openPaged() async throws -> FakeThread {
        let thread = FakeThread(ThreadFixture.snapshot([]), history: Self.session, deckHosting: true)
        try await thread.waitUntilReady()
        await thread.store.loadOlder()
        await thread.store.loadOlder()
        ListPerf.settle(thread.window)
        #expect(thread.store.messages.count > 2 * FakeThread.pageSize, "it holds older pages: \(thread.store.messages.count) messages")
        return thread
    }

    /// The thread is hidden, and the stores around it have shown another thread since, past `retainedHistories`, so the bounds take
    /// what they take of it. Returns once the hidden view has drawn what it kept: it records that as it is drawn
    /// (`ThreadRestore.plan`), and a thread shown before it has was never let go as far as the restore is concerned.
    @discardableResult
    private func leaveTheDeck(_ thread: FakeThread) async throws -> NativeThreadStores<String> {
        let stores = NativeThreadStores<String>()
        stores.retainedHistories = 0
        stores.install(thread.store, for: "away")
        let other = stores.store(for: "other")
        other.preview(ThreadFixture.snapshot(ThreadFixture.history(4)))
        stores.noteShown("away")
        try await thread.show(false)
        stores.noteShown("other")
        stores.enforceHistoryBounds()
        let store = thread.store
        try await eventuallyOnMain("the hidden thread to draw only what it kept") {
            ListPerf.settle(thread.window)
            guard store.keepsOnlyTail, let kept = store.transcriptDrawn else { return false }
            return ThreadRowMemory.built(in: store) <= kept
        }
        return stores
    }

    /// Runs `sample` on each of `polls` polls of `eventuallyOnMain`. A thing that must not happen cannot be waited for, so the window it
    /// is watched over is a count of polls (10 ms each), longer than the looks the restore makes meanwhile (`AppLayout.restoreRetry`).
    private func watch(_ what: String, polls: Int, _ sample: @MainActor () throws -> Void) async throws {
        var taken = 0
        try await eventuallyOnMain(what) {
            try sample()
            taken += 1
            return taken >= polls
        }
    }

    /// Polls that span `looks` looks of the restore.
    private static func polls(looks: Int) -> Int { looks * Int(AppLayout.restoreRetry / .milliseconds(10)) + 1 }

    private func distanceFromTail(_ thread: FakeThread) throws -> CGFloat {
        let scroll = try #require(thread.scrollView)
        let document = try #require(scroll.documentView)
        let clip = scroll.contentView
        return document.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scroll.contentInsets.bottom)
    }

    @Test func aThreadPastTheBoundsDrawsItsLastScreenBeforeItsPullReturns() async throws {
        let thread = try await openPaged()
        defer { thread.close() }
        try await leaveTheDeck(thread)
        let store = thread.store
        let tail = Array(Self.session.suffix(10))
        #expect(store.messages.suffix(10) == tail, "the end of the thread is what it kept")
        #expect(!store.rows.isEmpty && store.holdsHistory && store.keptRows > 0)

        // The thread comes back with its pull on its way.
        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        defer { thread.releaseSnapshots() }
        let first = ThreadRowMemory.built(in: store)
        #expect(first >= store.keptRows, "its first frame drew the rows it kept: \(first) rows built of \(store.keptRows)")
        #expect(try abs(distanceFromTail(thread)) < 2, "at the end of the thread")
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }

        thread.releaseSnapshots()
        try await eventuallyOnMain("the rest of its tail to come back", timeout: .seconds(30)) {
            ListPerf.settle(thread.window)
            return ThreadRowMemory.built(in: store) >= min(store.rows.count, ThreadView.eagerRows)
        }
        #expect(try abs(distanceFromTail(thread)) < 2, "at the end of the thread")
    }

    @Test func aPullThatLandsAfterTheFirstFrameMovesNothingAndBuildsNoRowAgain() async throws {
        let thread = try await openPaged()
        defer { thread.close() }
        try await leaveTheDeck(thread)
        let store = thread.store
        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        defer { thread.releaseSnapshots() }
        let ids = store.rows.suffix(ThreadView.eagerRows).map(\.id)
        #expect(ids.count == ThreadView.eagerRows && store.keptRows > 0)
        var built = [ThreadRowMemory.built(in: store)]
        var distances = [try distanceFromTail(thread)]
        #expect(built[0] >= store.keptRows, "the first frame drew what it kept: \(built[0]) rows")
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }

        thread.releaseSnapshots()
        try await eventuallyOnMain("the pull to land") { store.catchUp != nil }
        var still = 0
        try await eventuallyOnMain("the rest of its tail to come back", timeout: .seconds(30)) {
            ListPerf.settle(thread.window)
            built.append(ThreadRowMemory.built(in: store))
            distances.append(try distanceFromTail(thread))
            still = built.last == built.dropLast().last ? still + 1 : 0
            return built.last! >= ids.count && still >= 5
        }
        #expect(store.rows.suffix(ids.count).map(\.id) == ids, "the rows it drew are the rows it has, with the same identities")
        #expect(built == built.sorted(), "no row was built again, none went: \(built)")
        #expect(distances.allSatisfy { abs($0) < 2 }, "the reader stayed at the end of the thread: \(distances)")
    }

    /// The replies of an ordinary working thread: a few lines of prose, or a few blocks of about two kilobytes.
    enum Replies: CaseIterable, CustomTestStringConvertible {
        case twoParagraphs, threeParagraphs, eightParagraphs, twoKilobytesOfBlocks

        var testDescription: String { "\(self)" }

        func text(_ i: Int) -> String {
            let paragraph = "Answer paragraph with enough words to wrap a line or two in the column, like a real reply."
            switch self {
            case .twoParagraphs: return "\(i). " + Array(repeating: paragraph, count: 2).joined(separator: "\n\n")
            case .threeParagraphs: return "\(i). " + Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
            case .eightParagraphs: return "\(i). " + Array(repeating: paragraph, count: 8).joined(separator: "\n\n")
            case .twoKilobytesOfBlocks: return MarkdownFixtures.longReply(cycles: 5, from: i * 5)
            }
        }

        /// 40 questions and their answers.
        var session: [NativeThreadMessage] {
            (0..<40).flatMap { i in [ThreadFixture.user("u\(i)", "Question \(i)"), ThreadFixture.assistant("a\(i)", text(i))] }
        }
    }

    /// What the thread's scroll view shows above its composer, from one capture of the window.
    private func drawing(_ thread: FakeThread) throws -> Drawing {
        let scroll = try #require(thread.scrollView)
        var region = scroll.convert(scroll.bounds, to: thread.window.host)
        region.size.height = max(1, region.height - scroll.contentInsets.bottom - 24)
        let capture = FrameTimer.capture(thread.window, region)
        return Drawing(ink: capture.ink, longestBlankBand: capture.longestBlankBand, inkBottom: capture.inkBottom)
    }

    private struct Drawing: Equatable, CustomStringConvertible {
        let ink: Int
        let longestBlankBand: Int
        let inkBottom: Int

        var description: String { "ink \(ink), blank band \(longestBlankBand) pt, lowest ink \(inkBottom)" }

        /// Draws what `settled` does of the window: no more blank stretch, and at least nine tenths of its ink (the last row of a settled
        /// thread draws a footer under it that a thread coming back has not).
        func covers(like settled: Drawing) -> Bool { longestBlankBand <= settled.longestBlankBand && ink * 10 >= settled.ink * 9 }
    }

    /// A thread of ordinary replies that held the host's newest page and was left past the history bounds: it keeps that page, and its
    /// hidden view draws only the last screen of it. Returns the thread and what the window showed while it was settled on screen. The
    /// view counts of a thread like this say little about its first frame: the rows it draws first are few beside the whole page.
    private func openOrdinaryOffTheDeck(_ replies: Replies) async throws -> (thread: FakeThread, settled: Drawing) {
        let thread = FakeThread(ThreadFixture.snapshot([]), history: replies.session, deckHosting: true)
        do {
            try await thread.waitUntilReady()
            await thread.store.waitForProse()
            ListPerf.settle(thread.window)
            let store = thread.store
            #expect(store.messages.count == FakeThread.pageSize && store.rows.count == FakeThread.pageSize, "the host's newest page: \(store.messages.count) messages, \(store.rows.count) rows")
            let settled = try drawing(thread)
            try await leaveTheDeck(thread)
            #expect(store.keepsOnlyTail && store.messages.count == FakeThread.pageSize, "it keeps its page: \(store.messages.count) messages")
            #expect(store.keptRows > 0 && store.keptRows < ThreadView.eagerRows, "its hidden view kept a last screen of \(store.keptRows) rows, with more to come")
            return (thread, settled)
        } catch {
            thread.close()
            throw error
        }
    }

    /// Shows the thread with its pull on its way, and what its first frame draws.
    private func showWithHeldPull(_ thread: FakeThread) async throws -> Drawing {
        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        let frame = try drawing(thread)
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }
        return frame
    }

    /// A thread of ordinary replies, shown after it kept only its page, draws rows that cover the window in its first frame, before its
    /// pull returns: what the window shows once the thread has settled, from what the store holds, with the rest of the page still to come
    /// above them. A last screen of a few short rows would leave the top of the window empty until the pull had landed.
    @Test(arguments: Replies.allCases)
    func anOrdinaryThreadPastTheBoundsDrawsWhatTheWindowShowsBeforeItsPullReturns(replies: Replies) async throws {
        let (thread, settled) = try await openOrdinaryOffTheDeck(replies)
        defer { thread.close() }
        defer { thread.releaseSnapshots() }
        let store = thread.store

        let frame = try await showWithHeldPull(thread)
        let first = ThreadRowMemory.built(in: store)
        #expect(first >= store.keptRows && first < store.rows.count, "its first frame drew the rows it kept and not the whole page: \(first) rows built, \(store.keptRows) kept, \(store.rows.count) in the thread")
        #expect(frame.covers(like: settled), "its first frame shows what the settled thread does of the window: \(frame), settled \(settled)")
        #expect(try abs(distanceFromTail(thread)) < 2, "at the end of the thread")
    }

    /// The rest of the page comes back above those rows over the frames after it, and the window shows the same thing in each of them: the
    /// reader is at the end of the thread throughout, and no row that was drawn goes.
    @Test(arguments: Replies.allCases)
    func theRestOfAnOrdinaryThreadFillsInAboveItsFirstFrameWithoutChangingWhatTheWindowShows(replies: Replies) async throws {
        let (thread, settled) = try await openOrdinaryOffTheDeck(replies)
        defer { thread.close() }
        defer { thread.releaseSnapshots() }
        let store = thread.store

        _ = try await showWithHeldPull(thread)
        var built = [ThreadRowMemory.built(in: store)]
        var drawings = [try drawing(thread)]
        var distances = [try distanceFromTail(thread)]
        thread.releaseSnapshots()
        var still = 0
        try await eventuallyOnMain("the rest of its tail to come back", timeout: .seconds(30)) {
            ListPerf.settle(thread.window)
            built.append(ThreadRowMemory.built(in: store))
            drawings.append(try drawing(thread))
            distances.append(try distanceFromTail(thread))
            still = built.last == built.dropLast().last ? still + 1 : 0
            return built.last! >= min(store.rows.count, ThreadView.eagerRows) && still >= 5
        }
        #expect(Set(built).count >= 2, "the rest came back after the first frame: \(built)")
        #expect(built == built.sorted(), "no row was built again, none went: \(built)")
        #expect(drawings.allSatisfy { $0.covers(like: settled) }, "the window showed what the settled thread does of it, in every frame: \(Set(drawings.map(\.description)).sorted()), settled \(settled)")
        #expect(distances.allSatisfy { abs($0) < 2 }, "the reader stayed at the end of the thread: \(distances), rows built \(built), ink \(drawings.map(\.ink))")
    }

    /// A thread of heavy rows, whose eager tail is a few of them with more above: its first frame draws that tail alone, from what it kept,
    /// and the lazy stack of the older rows waits for the pull that catches it up. Neither moves the end of the thread.
    @Test func aHeavyThreadDrawsItsEagerTailAloneAndItsStackAfterThePull() async throws {
        let messages = ThreadEagerTailTests.messages(turns: 40, cycles: ThreadEagerTailTests.cycles)
        let thread = FakeThread(ThreadFixture.snapshot(messages), deckHosting: true)
        try await thread.waitUntilReady()
        await thread.store.waitForProse()
        ListPerf.settle(thread.window)
        let tail = try #require(thread.store.drawnEagerRows)
        #expect(tail < ThreadView.eagerRows / 2, "its tail is bound by cost: \(tail) rows")
        defer { thread.close() }
        try await leaveTheDeck(thread)
        let store = thread.store
        #expect(store.keepsOnlyTail && store.rows.count > tail)

        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        defer { thread.releaseSnapshots() }
        let first = ThreadRowMemory.built(in: store)
        #expect(first > 0 && first <= tail, "the first frame drew the eager tail alone: \(first) rows of \(tail), \(store.rows.count) in the thread")
        #expect(try abs(distanceFromTail(thread)) < 2)

        // The lazy stack waits for the pull while it is held: no frame until it lands has more than the tail.
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }
        var held = [first]
        try await watch("the held pull to be watched for three looks of the restore", polls: Self.polls(looks: 3)) {
            ListPerf.settle(thread.window)
            held.append(ThreadRowMemory.built(in: store))
        }
        #expect(store.catchUp == nil && held.allSatisfy { $0 <= tail }, "the stack stayed out while the pull was held: \(held), tail \(tail)")

        thread.releaseSnapshots()
        try await eventuallyOnMain("the pull to land") { store.catchUp != nil }
        var distances: [CGFloat] = []
        try await watch("the end of the thread to be watched as the stack comes", polls: Self.polls(looks: 3)) {
            ListPerf.settle(thread.window)
            distances.append(try distanceFromTail(thread))
        }
        #expect(ThreadRowMemory.built(in: store) >= first)
        #expect(distances.allSatisfy { abs($0) < 2 }, "the end of the thread stayed where it was: \(distances)")
    }

    /// The pull that was to catch a thread that kept only its tail up fails (the host cannot serve it), or pi is held off: nothing is going
    /// to move its tail or add rows above it, so its lazy stack does not wait for it for as long as `AppLayout.restoreParseRetries`
    /// looks, three seconds in which the reader cannot scroll above the tail.
    @Test(arguments: [false, true])
    func aHeavyThreadWhosePullIsNotComingBringsItsStackWithoutWaitingTheWholeBound(piHeldOff: Bool) async throws {
        let (thread, tail) = try await openHeavyOffTheDeck()
        defer { thread.close() }
        let store = thread.store

        let requests = thread.snapshotRequests
        thread.failing = !piHeldOff
        thread.starting = piHeldOff
        store.offline = piHeldOff
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        let first = ThreadRowMemory.built(in: store)
        #expect(first > 0 && first <= tail, "the first frame drew the eager tail alone: \(first) rows of \(tail)")
        try await eventuallyOnMain("the pull to have ended") { thread.snapshotRequests > requests && !store.ready && store.catchUpFailed }
        let bound = AppLayout.restoreRetry * AppLayout.restoreParseRetries
        try await eventuallyOnMain("the lazy stack to come before the bound the pull is waited for", timeout: bound - AppLayout.restoreRetry * 5) {
            ListPerf.settle(thread.window)
            return ThreadRowMemory.built(in: store) > tail
        }
        #expect(store.catchUp == nil, "the thread was never caught up")
        #expect(try abs(distanceFromTail(thread)) < 2, "the end of the thread stayed where it was")
    }

    /// A pi that is starting will answer, usually within seconds, and what its snapshot brings changes the tail: the lazy stack waits for it
    /// as it waits for a pull that is held, and comes once it has landed.
    @Test func aHeavyThreadWhosePiIsStartingKeepsItsStackOutUntilItsSnapshotLands() async throws {
        let (thread, tail) = try await openHeavyOffTheDeck()
        defer { thread.close() }
        let store = thread.store

        let requests = thread.snapshotRequests
        thread.starting = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        let first = ThreadRowMemory.built(in: store)
        #expect(first > 0 && first <= tail, "the first frame drew the eager tail alone: \(first) rows of \(tail)")
        try await eventuallyOnMain("pi to have answered that it is starting") { thread.snapshotRequests > requests && store.starting }
        var held = [first]
        try await watch("the starting pi to be watched for three looks of the restore", polls: Self.polls(looks: 3)) {
            ListPerf.settle(thread.window)
            held.append(ThreadRowMemory.built(in: store))
        }
        #expect(store.catchUp == nil && !store.catchUpFailed && held.allSatisfy { $0 <= tail }, "the stack stayed out while pi started: \(held), tail \(tail)")

        thread.starting = false
        try await eventuallyOnMain("the pull to land") { store.catchUp != nil }
        try await eventuallyOnMain("the lazy stack to come", timeout: .seconds(30)) {
            ListPerf.settle(thread.window)
            return ThreadRowMemory.built(in: store) > tail
        }
        #expect(try abs(distanceFromTail(thread)) < 2, "the end of the thread stayed where it was")
    }

    /// The window is dragged while the pull that catches a thread that kept only its tail up is still on its way. The history above the
    /// tail stands down for the drag (`ThreadView.parksHistory`) and the lazy stack waits for the pull (`ThreadView.restoreRows`), each
    /// on its own: the stack stays out while the pull is held, drag or none, and is in the document again once both are over, whichever
    /// ends first, with the end of the thread where it was.
    @Test(arguments: [true, false])
    func aDragThroughAHeldPullLeavesTheStackToComeOnceBothAreOver(dragEndsFirst: Bool) async throws {
        let (thread, tail) = try await openHeavyOffTheDeck()
        defer { thread.close() }
        let store = thread.store
        let scroll = try #require(thread.scrollView)
        let window = thread.window.window
        let size = try #require(window.contentView).bounds.size

        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        defer { thread.releaseSnapshots() }
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }
        let tailOnly = scroll.documentView?.frame.height ?? 0

        thread.visibility.liveResizing = true
        ListPerf.settle(thread.window)
        for step in 1...4 {
            window.setContentSize(NSSize(width: size.width - CGFloat(step) * 30, height: size.height))
            ListPerf.settle(thread.window)
        }
        func endDrag() {
            window.setContentSize(size)
            thread.visibility.liveResizing = false
        }
        func landThePull() async throws {
            thread.releaseSnapshots()
            try await eventuallyOnMain("the pull to land") { store.catchUp != nil }
        }
        var held = [ThreadRowMemory.built(in: store)]
        func watchTheStackStayOut(_ what: String) async throws {
            try await watch(what, polls: Self.polls(looks: 3)) {
                ListPerf.settle(thread.window)
                held.append(ThreadRowMemory.built(in: store))
            }
        }
        if dragEndsFirst {
            endDrag()
            try await watchTheStackStayOut("the held pull to be watched after the drag")
            #expect(store.catchUp == nil && held.allSatisfy { $0 <= tail }, "the stack stayed out while the pull was held: \(held), tail \(tail)")
            try await landThePull()
        } else {
            try await landThePull()
            try await watchTheStackStayOut("the drag to be watched after the pull landed")
            #expect(held.allSatisfy { $0 <= tail }, "the history stood down for the drag: \(held), tail \(tail)")
            endDrag()
        }
        var joined = tailOnly
        try await eventuallyOnMain("the history back in the document, many tails tall", timeout: .seconds(30)) {
            ListPerf.settle(thread.window)
            joined = scroll.documentView?.frame.height ?? 0
            return joined > tailOnly * 4
        }
        #expect(try abs(distanceFromTail(thread)) < 2, "the end of the thread stayed where it was, after a document of \(tailOnly) became \(joined)")
    }

    /// A thread of heavy rows that kept only its tail and is off the deck: the thread, and the rows its eager tail draws.
    private func openHeavyOffTheDeck() async throws -> (FakeThread, tail: Int) {
        let messages = ThreadEagerTailTests.messages(turns: 40, cycles: ThreadEagerTailTests.cycles)
        let thread = FakeThread(ThreadFixture.snapshot(messages), deckHosting: true)
        do {
            try await thread.waitUntilReady()
            await thread.store.waitForProse()
            ListPerf.settle(thread.window)
            let tail = try #require(thread.store.drawnEagerRows)
            #expect(tail < ThreadView.eagerRows / 2, "its tail is bound by cost: \(tail) rows")
            try await leaveTheDeck(thread)
            #expect(thread.store.keepsOnlyTail && thread.store.rows.count > tail)
            return (thread, tail)
        } catch {
            thread.close()
            throw error
        }
    }
}

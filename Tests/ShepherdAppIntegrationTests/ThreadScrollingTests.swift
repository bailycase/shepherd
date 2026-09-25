import AppKit
import Foundation
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
import Vision
@testable import ShepherdApp

/// A real `ThreadView` in an off-screen window, fed snapshots the test controls. Nothing here
/// sends mouse or keyboard events: "the user moved" is the ⌥⌘↑/↓ turn commands (the same
/// path the menu takes) or a programmatic scroll of the clip view.
@MainActor
private final class ThreadHarness {
    let store = NativeThreadStore()
    let commands = ThreadCommandCenter()
    var snapshot: NativeThreadSnapshot
    let window: OffscreenWindow

    init(messages: Int, running: Bool = false, paragraphs: Int = 3) {
        let snapshot = Self.snapshot(count: messages, running: running, paragraphs: paragraphs)
        self.snapshot = snapshot
        window = OffscreenWindow(size: CGSize(width: 900, height: 600), dark: false)
        let request: NativeThreadStore.Request = { [weak self] value in
            guard let self else { return .failure(code: "gone", message: "harness released") }
            if case .send(_, _, let operation, _, _, _) = value { return .accepted(operationID: operation) }
            return .snapshot(value: self.snapshot)
        }
        window.show(ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "thread")
            .environment(\.threadCommands, commands))
    }

    /// `count` alternating user/assistant messages; each answer is `paragraphs` paragraphs.
    static func snapshot(count: Int, running: Bool, revision: UInt64 = 1, prefix: String = "m", paragraphs: Int = 3) -> NativeThreadSnapshot {
        let messages = (0..<count).map { index -> NativeThreadMessage in
            let user = index % 2 == 0
            let text = user ? "Question \(index)"
                : Array(repeating: "Answer paragraph \(index) with enough words to wrap a line or two in the column.", count: paragraphs).joined(separator: "\n\n")
            return NativeThreadMessage(entryID: "\(prefix)\(index)", role: user ? "user" : "assistant",
                                       blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
        }
        return NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: running,
                                    supportedActions: ["send", "abort"], dialogsSupported: true, dialogs: [],
                                    messages: messages, provisional: [], clipped: false)
    }

    /// Serve `next` and pull it now rather than waiting for the poll.
    func publish(_ next: NativeThreadSnapshot) async {
        snapshot = next
        await store.refresh()
        window.layout()
    }

    var scrollView: NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window.host)!
    }

    /// How far the visible bottom edge sits above the end of the content (the composer is a
    /// bottom inset, so "visible" stops above it).
    var distanceFromBottom: CGFloat {
        window.layout()
        let clip = scrollView.contentView
        return scrollView.documentView!.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scrollView.contentInsets.bottom)
    }

    /// Blank space between the last laid-out row and the end of the document.
    var trailingSpace: CGFloat {
        window.layout()
        let document = scrollView.documentView!
        let lastRow = document.subviews.flatMap(\.subviews).map(\.frame.maxY).max() ?? 0
        return document.bounds.height - lastRow
    }

    /// At the tail: within the follower's threshold of the bottom and never scrolled past the
    /// end (content shorter than the viewport reads negative and still counts).
    var isPinned: Bool {
        let distance = distanceFromBottom
        let clip = scrollView.contentView
        let visible = clip.bounds.height - scrollView.contentInsets.bottom - scrollView.contentInsets.top
        let fits = scrollView.documentView!.bounds.height <= visible + 1
        return distance <= NativeScrollFollower.threshold && (distance >= -1 || fits)
    }

    /// Whether the "Jump to latest" pill is on screen, read from the rendered window (SwiftUI
    /// buttons are not NSViews, and the accessibility tree is empty without an AX client).
    var showsJumpPill: Bool {
        window.layout()
        let host = window.host
        // The pill floats just above the composer: OCR only the lower half.
        let region = NSRect(x: 0, y: host.isFlipped ? host.bounds.height / 2 : 0, width: host.bounds.width, height: host.bounds.height / 2)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: region) else { return false }
        host.cacheDisplay(in: region, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).contains {
            $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains("Jump to latest") == true
        }
    }

    /// Scrolls the clip view to the end, the way a reader dragging to the bottom lands.
    func scrollToEnd() {
        let clip = scrollView.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: scrollView.documentView!.bounds.height), size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        window.layout()
    }

    func command(_ command: ThreadCommandCenter.Command) {
        commands.send(command, to: "thread")
        window.layout()
    }

    /// Scrolls the clip view programmatically so the visible bottom sits `distance` above the
    /// end. Not reader intent: the follower's stickiness is unchanged.
    func scroll(toDistance distance: CGFloat) {
        window.layout()
        let clip = scrollView.contentView
        let y = scrollView.documentView!.bounds.height - clip.bounds.height + scrollView.contentInsets.bottom - distance
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        window.layout()
    }

    /// Detaches with ⌥⌘↑. The jump starts from a position already well above the tail: a jump
    /// animated from the tail itself passes within the follower's threshold, and whether an
    /// early frame re-sticks it depends on frame timing (see the report on this suite).
    func detach() async throws {
        scroll(toDistance: 900)
        try await settle()
        command(.previousTurn)
        try await settle()
    }

    /// ⌥⌘↓ until the view is back at the tail: past the last turn it jumps to the latest.
    func jumpDownToTheTail() async throws {
        var trail: [Int] = []
        while !isPinned {
            trail.append(Int(distanceFromBottom))
            guard trail.count <= 12 else { throw TimedOut(what: "turn jumps to return to the tail (distances \(trail))") }
            command(.nextTurn)
            try await settle()
        }
    }

    /// Waits until the scroll position stops changing (an animated jump has landed).
    func settle() async throws {
        var last = distanceFromBottom, still = 0
        try await eventuallyOnMain("the scroll view to come to rest", timeout: .seconds(10), poll: .milliseconds(30)) {
            let now = distanceFromBottom
            still = abs(now - last) < 0.5 ? still + 1 : 0
            last = now
            return still >= 4
        }
    }

    func waitUntilReady() async throws {
        try await eventuallyOnMain("the thread to load") { store.ready }
        try await eventuallyOnMain("the thread to open at its tail") { isPinned }
    }

    func close() {
        store.stop()
        window.close()
    }
}

/// Serialized: each test owns a window and reads it back, and the main thread's layout
/// passes are the thing under test.
@Suite("Thread scroll following", .serialized, .mainActorExclusive)
@MainActor
struct ThreadScrollingTests {
    @Test func aThreadOpensAtItsTailWithNoBlankSpaceBelowTheLastTurn() async throws {
        let thread = ThreadHarness(messages: 24)
        defer { thread.close() }

        try await thread.waitUntilReady()

        #expect(thread.trailingSpace <= AppLayout.turnSpacing * 2 + 13, "blank space after the last turn: \(thread.trailingSpace)")
        thread.scrollToEnd()
        #expect(thread.distanceFromBottom >= -1 && thread.distanceFromBottom < 2, "scrolled past the end: \(thread.distanceFromBottom)")
    }

    @Test func streamingGrowthKeepsThePinnedTailInViewWithoutThePill() async throws {
        let thread = ThreadHarness(messages: 2, running: true)
        defer { thread.close() }
        try await thread.waitUntilReady()

        // Short content (negative distance) growing well past the viewport is layout, not intent.
        for (index, count) in [4, 8, 14, 22, 30].enumerated() {
            await thread.publish(ThreadHarness.snapshot(count: count, running: true, revision: UInt64(index + 2)))
            try await eventuallyOnMain("the tail to follow growth to \(count) messages") { thread.isPinned }
            #expect(!thread.showsJumpPill, "pill shown after growing to \(count)")
        }
    }

    /// A turn ending swaps provisional rows for history: content shrinks, then grows.
    @Test func finishingATurnKeepsTheTailAndHidesThePill() async throws {
        let thread = ThreadHarness(messages: 20, running: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        var running = ThreadHarness.snapshot(count: 20, running: true, revision: 2)
        running.provisional = [
            NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant",
                                blocks: [NativeThreadBlock(kind: .text, text: "streaming a paragraph of text that wraps onto two lines at least")],
                                status: "streaming", truncated: false),
            NativeThreadMessage(entryID: "provisional:tool:c1", role: "toolResult", blocks: [], toolName: "bash", toolCallID: "c1",
                                argumentsText: "{\"command\":\"ls\"}", status: "running", truncated: false),
        ]
        await thread.publish(running)
        try await eventuallyOnMain("the tail to follow the provisional rows") { thread.isPinned }

        await thread.publish(ThreadHarness.snapshot(count: 21, running: false, revision: 3))

        try await eventuallyOnMain("the turn to settle") { !thread.store.settledRunning }
        try await eventuallyOnMain("the tail to stay pinned") { thread.isPinned }
        #expect(!thread.showsJumpPill)
    }

    /// The composer changing height moves the scroll view's inset; that is not the reader.
    @Test func theComposerGrowingOrShrinkingKeepsTheTail() async throws {
        let thread = ThreadHarness(messages: 24)
        defer { thread.close() }
        try await thread.waitUntilReady()

        thread.store.draft = (1...5).map { "line \($0)" }.joined(separator: "\n")
        try await eventuallyOnMain("the tail to stay pinned above a taller composer") { thread.distanceFromBottom < 2 }
        thread.store.draft = ""
        try await eventuallyOnMain("the tail to stay pinned above a shorter composer") { thread.distanceFromBottom < 2 }
        #expect(!thread.showsJumpPill)
    }

    /// A live send: the echo appears, pi starts running, and a tool row streams in below the
    /// echo. The tail stays pinned throughout and the echo never drops below the reply.
    @Test func sendingKeepsTheTailAndTheEchoAboveTheReply() async throws {
        let thread = ThreadHarness(messages: 12)
        defer { thread.close() }
        try await thread.waitUntilReady()

        thread.store.draft = "spawn some agent"
        await thread.store.send()
        #expect(thread.store.sentCount == 1)
        var running = ThreadHarness.snapshot(count: 12, running: true, revision: 2)
        running.provisional = [
            NativeThreadMessage(entryID: "provisional:tool:c1", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "Run fan-out: 0/32 used")],
                                toolName: "subagent", toolCallID: "c1", argumentsText: "{\"agent\":\"delegate\"}", status: "complete", truncated: false),
        ]
        await thread.publish(running)

        try await eventuallyOnMain("the tail to stay pinned with the reply streaming") { thread.isPinned }
        #expect(!thread.showsJumpPill)
        let ids = thread.store.displayedMessages.map(\.entryID)
        let echo = try #require(ids.firstIndex { $0.hasPrefix("pending:") })
        #expect(echo < (ids.firstIndex(of: "provisional:tool:c1") ?? -1), "echo below reply: \(ids)")
        var persisted = running
        persisted.revision = 3
        persisted.messages.append(NativeThreadMessage(entryID: "m12", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "spawn some agent")], truncated: false))
        await thread.publish(persisted)
        #expect(thread.store.pending.isEmpty)
        try await eventuallyOnMain("the tail to stay pinned once pi persists the prompt") { thread.isPinned }
    }

    /// The server's bounded history window can be replaced by a much shorter one; the pinned
    /// view lands on the new tail, never on blank space past it.
    @Test func historyShrinkingUnderAPinnedViewLandsOnTheNewTail() async throws {
        let thread = ThreadHarness(messages: 60, running: true)
        defer { thread.close() }
        try await thread.waitUntilReady()

        await thread.publish(ThreadHarness.snapshot(count: 8, running: true, revision: 2, prefix: "w"))

        try await eventuallyOnMain("the view to land on the shorter tail") { thread.store.messages.count == 8 && thread.isPinned }
    }

    @Test func sendingWhileTheHistoryWindowSlidesStaysOnTheNewestContent() async throws {
        let thread = ThreadHarness(messages: 40)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = "next step please"
        await thread.store.send()

        for revision in 2...4 {
            var next = ThreadHarness.snapshot(count: 44 + revision * 4, running: revision < 4, revision: UInt64(revision))
            next.messages = Array(next.messages.dropFirst(revision * 6))
            next.messages.append(NativeThreadMessage(entryID: "u-sent", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "next step please")], truncated: false))
            next.olderCursor = next.messages.first?.entryID
            await thread.publish(next)
            try await eventuallyOnMain("the view to stay on the tail after revision \(revision)") { thread.isPinned }
        }
        #expect(!thread.showsJumpPill)
    }

    /// ⌥⌘↑ jumps to an earlier turn and detaches: growth no longer pulls the reader down, and
    /// the pill offers the way back while pi runs.
    @Test func jumpingToAnEarlierTurnDetachesFromTheTail() async throws {
        let thread = ThreadHarness(messages: 24, running: true, paragraphs: 20)
        defer { thread.close() }
        try await thread.waitUntilReady()

        try await thread.detach()
        let detached = thread.distanceFromBottom
        #expect(detached > NativeScrollFollower.threshold)
        await thread.publish(ThreadHarness.snapshot(count: 30, running: true, revision: 2, paragraphs: 20))

        try await thread.settle()
        #expect(thread.distanceFromBottom >= detached - 2, "growth yanked a detached reader back down")
        try await eventuallyOnMain("the jump pill to show", poll: .milliseconds(150)) { thread.showsJumpPill }
    }

    /// ⌥⌘↑ from the tail to a turn just over the follower's threshold above it: the jump's
    /// animation starts inside the threshold, and those first frames once re-stuck the follower,
    /// so the next streamed chunk yanked the reader back to the bottom (no pill).
    @Test func aJumpFromTheTailToANearbyTurnStaysDetachedWhileStreaming() async throws {
        let thread = ThreadHarness(messages: 24, running: true, paragraphs: 16)
        defer { thread.close() }
        try await thread.waitUntilReady()

        thread.command(.previousTurn)
        // The jump's spring starts from rest: its first frames barely move, and a busy main
        // thread can hold them back longer than `settle` waits for stillness.
        try await eventuallyOnMain("the jump to leave the tail") { thread.distanceFromBottom > NativeScrollFollower.threshold }
        try await thread.settle()
        let detached = thread.distanceFromBottom
        #expect(detached > NativeScrollFollower.threshold)
        await thread.publish(ThreadHarness.snapshot(count: 30, running: true, revision: 2, paragraphs: 16))
        try await thread.settle()

        #expect(thread.distanceFromBottom >= detached - 2, "growth yanked the reader back to the bottom")
        #expect(thread.showsJumpPill)
    }

    /// Returning to the bottom — by the next-turn command past the last turn, or by scrolling
    /// there — re-attaches: growth is followed again and the pill goes away.
    @Test(arguments: ["command", "scroll"])
    func returningToTheBottomReattachesToTheTail(how: String) async throws {
        let thread = ThreadHarness(messages: 24, running: true, paragraphs: 20)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await thread.detach()
        try await eventuallyOnMain("the jump pill to show", poll: .milliseconds(150)) { thread.showsJumpPill }

        if how == "command" { try await thread.jumpDownToTheTail() } else { thread.scrollToEnd() }

        try await eventuallyOnMain("the view to return to the tail") { thread.isPinned }
        try await eventuallyOnMain("the pill to go away", poll: .milliseconds(150)) { !thread.showsJumpPill }
        await thread.publish(ThreadHarness.snapshot(count: 34, running: true, revision: 2, paragraphs: 20))
        try await eventuallyOnMain("growth to be followed again") { thread.isPinned }
    }

    @Test func sendingFromAnEarlierTurnReturnsToTheTail() async throws {
        let thread = ThreadHarness(messages: 30, paragraphs: 20)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await thread.detach()
        #expect(thread.distanceFromBottom > NativeScrollFollower.threshold)

        thread.store.draft = "A brand new question from the user"
        await thread.store.send()

        #expect(thread.store.displayedMessages.last?.entryID.hasPrefix("pending:") == true)
        try await eventuallyOnMain("sending to bring the view back to the tail") { thread.distanceFromBottom < 2 }
        #expect(thread.trailingSpace <= AppLayout.turnSpacing * 2 + 13)
    }

    /// A follow-up sent while pi works waits in Up next. When it goes, after the reader left the
    /// tail, it is new output like any other: the reader keeps their place and the pill offers
    /// the way down. It once armed a scroll at the send that fired on its delivery.
    @Test func aQueuedFollowUpGoingInWhileDetachedKeepsTheReadersPlace() async throws {
        let thread = ThreadHarness(messages: 24, running: true, paragraphs: 20)
        defer { thread.close() }
        try await thread.waitUntilReady()
        // A host that holds the queue: the follow-up shows in Up next, not the thread.
        var running = ThreadHarness.snapshot(count: 24, running: true, revision: 2, paragraphs: 20)
        running.queue = NativeQueue()
        await thread.publish(running)

        thread.store.draft = "and then this"
        await thread.store.send(delivery: .followUp)
        #expect(thread.store.lastSendQueued && thread.store.rows.last(where: \.isUser)?.id == "m22")
        try await thread.detach()
        let detached = thread.distanceFromBottom
        #expect(detached > NativeScrollFollower.threshold)

        var delivered = ThreadHarness.snapshot(count: 26, running: false, revision: 3, paragraphs: 20)
        delivered.queue = NativeQueue()
        delivered.messages[24] = NativeThreadMessage(entryID: "m24", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "and then this")],
                                                     truncated: false)
        await thread.publish(delivered)
        try await eventuallyOnMain("the queued message to join the thread") { thread.store.rows.last(where: \.isUser)?.id == "m24" }
        try await eventuallyOnMain("the turn to settle") { !thread.store.running }
        try await thread.settle()

        #expect(thread.distanceFromBottom >= detached - 2, "the queued message's delivery pulled the reader to the tail")
        try await eventuallyOnMain("the jump pill to show for the new output", poll: .milliseconds(150)) { thread.showsJumpPill }
    }

    /// ⌥⌘↑ with pi idle: the rows the jump reveals are measured on the way, which grows the
    /// content, but nothing new arrived, so there is no pill until something does.
    @Test func aTurnJumpWithPiIdleShowsThePillOnlyForNewOutput() async throws {
        let thread = ThreadHarness(messages: 30, paragraphs: 20)
        defer { thread.close() }
        try await thread.waitUntilReady()

        try await thread.detach()
        #expect(thread.distanceFromBottom > NativeScrollFollower.threshold)
        thread.command(.previousTurn)
        try await thread.settle()
        #expect(!thread.showsJumpPill, "the pill showed with pi idle and nothing new")

        await thread.publish(ThreadHarness.snapshot(count: 32, running: false, revision: 2, paragraphs: 20))
        try await eventuallyOnMain("the jump pill to show for the new turn", poll: .milliseconds(150)) { thread.showsJumpPill }
    }

    /// A code block scrolls sideways only when its longest line is wider than the column; one
    /// that fits draws its code with no scroll view, at the same place.
    @Test(arguments: [false, true]) func aCodeBlockScrollsSidewaysOnlyWhenItsLinesDoNotFit(wide: Bool) {
        let line = wide ? String(repeating: "let value = compute(value) ", count: 20) : "let value = compute(value)"
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200), dark: false,
                                     NWCodeBlock(line, language: "swift").frame(width: 460).padding(20))
        defer { window.close() }
        ListPerf.settle(window)
        func scrollViews(_ view: NSView) -> Int { (view is NSScrollView ? 1 : 0) + view.subviews.map(scrollViews).reduce(0, +) }
        #expect(scrollViews(window.host) == (wide ? 1 : 0))
    }
}

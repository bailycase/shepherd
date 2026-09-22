import AppKit
import SwiftUI
import Testing
import Vision
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// Real-window scroll behaviour of the native thread (AppKit scroll view under SwiftUI).
/// Serialized: one NSWindow at a time, and the display must be awake for layout.
@Suite("Native thread scrolling", .serialized)
@MainActor
struct NativeScrollTests {
    @MainActor private final class Fixture {
        let store = NativeThreadStore()
        var snapshot: NativeThreadSnapshot
        var window: NSWindow!
        var host: NSHostingView<AnyView>!

        init(messageCount: Int, running: Bool = false) throws {
            snapshot = Self.makeSnapshot(count: messageCount, running: running)
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let store = store
            let request: NativeThreadStore.Request = { [weak self] value in
                guard let self else { return .failure(code: "gone", message: "fixture released") }
                if case .send(_, _, let operation, _, _, _) = value { return .accepted(operationID: operation) }
                return .snapshot(value: self.snapshot)
            }
            host = NSHostingView(rootView: AnyView(
                DesktopNativeThreadView(store: store, active: true, isFocused: false, request: request)
                    .preferredColorScheme(.light)))
            window.contentView = host
            window.orderFront(nil)
        }

        func tearDown() { window.orderOut(nil); window.contentView = nil }

        static func makeSnapshot(count: Int, running: Bool, revision: UInt64 = 1) -> NativeThreadSnapshot {
            var messages: [NativeThreadMessage] = []
            for index in 0..<count {
                let user = index % 2 == 0
                let text = user ? "Question \(index)" : Array(repeating: "Answer paragraph \(index) with enough words to wrap a line or two in the column.", count: 3).joined(separator: "\n\n")
                messages.append(NativeThreadMessage(entryID: "m\(index)", role: user ? "user" : "assistant",
                                                    blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false))
            }
            return NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: running,
                                        supportedActions: ["send", "abort"], dialogsSupported: true, dialogs: [],
                                        messages: messages, provisional: [], clipped: false)
        }

        var scrollView: NSScrollView {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            return find(host)!
        }

        /// How far the visible bottom edge is from the content's bottom edge.
        var distanceFromBottom: CGFloat {
            let clip = scrollView.contentView
            // The composer is a bottom content inset: the visible bottom is above it.
            return scrollView.documentView!.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scrollView.contentInsets.bottom)
        }

        func layout() async throws {
            for _ in 0..<3 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
            }
        }

        /// A trackpad gesture delivered through AppKit: several pixel-unit scroll events with a
        /// phase, routed by NSApp to the scroll view under the pointer, exactly like a user.
        func wheel(deltaY: CGFloat) async throws {
            let location = window.convertPoint(toScreen: NSPoint(x: 450, y: 300))
            var flipped = location
            flipped.y = (NSScreen.screens.first?.frame.height ?? 0) - location.y
            let steps = 8
            for step in 0..<steps {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                       wheel1: Int32(deltaY / CGFloat(steps)), wheel2: 0, wheel3: 0) else { return }
                cg.location = flipped
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: step == 0 ? 1 : (step == steps - 1 ? 4 : 2))
                if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
                try await Task.sleep(for: .milliseconds(16))
            }
            try await layout()
        }
    }

    private func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @Test func opensAtTheBottomAndCannotScrollPastTheContent() async throws {
        let f = try Fixture(messageCount: 24)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        try await Task.sleep(for: .milliseconds(300))
        try await f.layout()
        // Opens pinned to the tail, within the follower's own "at the bottom" threshold (text layout
        // at some column widths lands a fractional point off).
        #expect(f.distanceFromBottom <= NativeScrollFollower.threshold, "expected to open at the bottom, distance \(f.distanceFromBottom)")
        // No trailing space: the document ends where the last turn ends (the composer is a
        // safe-area inset on the scroll view, not padding inside the content).
        let document = f.scrollView.documentView!
        let lastVisible = document.subviews.flatMap { $0.subviews }.map { $0.frame.maxY }.max() ?? 0
        let overflow = document.bounds.height - lastVisible
        let tail = document.subviews.flatMap { $0.subviews }.sorted { $0.frame.maxY > $1.frame.maxY }.prefix(4)
            .map { "\(type(of: $0)) \(Int($0.frame.minY))..\(Int($0.frame.maxY)) h=\(Int($0.frame.height))" }
        // Allowed trailing space: the bubble's own padding plus one turn spacing before the
        // 1pt bottom marker (the LazyVStack keeps the spacing before its last item).
        let allowance = NativeMetrics.turnSpacing + 12 + 1 + NativeMetrics.turnSpacing
        #expect(overflow <= allowance, "document \(Int(document.bounds.height)) has \(overflow)pt of blank space after the last turn; tail: \(tail); inset \(f.scrollView.contentInsets)")
        // Dragging further down cannot reveal blank space.
        let clip = f.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: document.bounds.height))
        f.scrollView.reflectScrolledClipView(clip)
        try await f.layout()
        #expect(f.distanceFromBottom >= -1 && f.distanceFromBottom < 2, "after dragging past the end: \(f.distanceFromBottom)")
    }

    @Test func growthKeepsTheTailPinnedUntilTheUserScrollsUp() async throws {
        let f = try Fixture(messageCount: 20, running: true)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        #expect(f.distanceFromBottom < 2)
        // Streaming: content grows; the tail stays pinned without user input.
        f.snapshot = Fixture.makeSnapshot(count: 26, running: true, revision: 2)
        try await waitFor { f.store.messages.count == 26 }
        try await f.layout()
        #expect(f.distanceFromBottom < 2, "growth detached the tail: \(f.distanceFromBottom)")
        // The user scrolls up: growth must no longer pull the view down.
        try await f.wheel(deltaY: 400)
        let detachedDistance = f.distanceFromBottom
        #expect(detachedDistance > 100, "wheel did not move the view: \(detachedDistance)")
        f.snapshot = Fixture.makeSnapshot(count: 32, running: true, revision: 3)
        try await waitFor { f.store.messages.count == 32 }
        try await f.layout()
        #expect(f.distanceFromBottom > detachedDistance - 2, "growth yanked a detached user back to the bottom")
    }

    /// A turn ending: the provisional assistant/tool rows vanish and history replaces them,
    /// so content shrinks a little, then grows. Neither step is the user; stay stuck.
    @Test func contentReplacementDoesNotDetachOrShowTheJumpPill() async throws {
        let f = try Fixture(messageCount: 20, running: true)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        #expect(f.distanceFromBottom < 2)
        // Running with two provisional rows.
        var mid = Fixture.makeSnapshot(count: 20, running: true, revision: 2)
        mid.provisional = [
            NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant",
                                blocks: [NativeThreadBlock(kind: .text, text: "streaming a fairly long paragraph of text that wraps onto two lines at least")], status: "streaming", truncated: false),
            NativeThreadMessage(entryID: "provisional:tool:c1", role: "toolResult", blocks: [], toolName: "bash", toolCallID: "c1",
                                argumentsText: "{\"command\":\"ls\"}", status: "running", truncated: false),
        ]
        f.snapshot = mid
        try await waitFor { f.store.snapshot?.revision == 2 }
        try await f.layout()
        #expect(f.distanceFromBottom < 2)
        // Turn ends: provisional gone, one shorter history message instead, still running=false.
        f.snapshot = Fixture.makeSnapshot(count: 21, running: false, revision: 3)
        try await waitFor { f.store.snapshot?.revision == 3 }
        try await f.layout()
        try await Task.sleep(for: .milliseconds(500))  // settledRunning debounce
        try await f.layout()
        #expect(f.distanceFromBottom < 2, "replacement detached the tail: \(f.distanceFromBottom)")
        // The jump pill must not be visible while pinned to the bottom.
        #expect(!jumpVisible(f.host), "jump pill shown while at the bottom")
    }

    /// A short thread (content shorter than the viewport) that grows past it: the offset is
    /// clamped at 0 the whole time, so "distance from bottom" is negative, then large. None
    /// of that is user intent; the tail must be followed and the pill must stay hidden.
    @Test func shortThreadGrowingPastTheViewportFollowsTheTail() async throws {
        let f = try Fixture(messageCount: 2, running: true)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        #expect(!jumpVisible(f.host))
        for (i, count) in [4, 8, 14, 22].enumerated() {
            f.snapshot = Fixture.makeSnapshot(count: count, running: true, revision: UInt64(i + 2))
            try await waitFor { f.store.messages.count == count }
            try await f.layout()
            #expect(!jumpVisible(f.host), "jump pill shown after growing to \(count)")
        }
        #expect(f.distanceFromBottom < 2, "tail not followed after growth: \(f.distanceFromBottom)")
    }

    /// The composer changes height (status line, attachments, multi-line draft). That moves the
    /// scroll view's inset, which SwiftUI reports as an offset change. It is not user intent.
    @Test func composerGrowthDoesNotDetach() async throws {
        let f = try Fixture(messageCount: 24)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        #expect(f.distanceFromBottom < 2)
        // A five-line draft grows the card by ~80pt.
        f.store.draft = (1...5).map { "line \($0)" }.joined(separator: "\n")
        try await f.layout()
        try await Task.sleep(for: .milliseconds(200))
        try await f.layout()
        #expect(f.distanceFromBottom < 2, "composer growth detached the tail: \(f.distanceFromBottom)")
        // Running toggles the working row and, before this fix, a status line in the composer.
        f.snapshot = Fixture.makeSnapshot(count: 24, running: true, revision: 2)
        try await waitFor { f.store.snapshot?.revision == 2 }
        try await f.layout()
        f.store.draft = ""
        try await f.layout()
        try await Task.sleep(for: .milliseconds(200))
        try await f.layout()
        #expect(f.distanceFromBottom < 2, "composer shrink detached the tail: \(f.distanceFromBottom)")
        #expect(!jumpVisible(f.host), "jump pill shown after composer resize")
    }

    /// Exactly what a live send looks like: at the bottom, send → echo appended → pi reports
    /// running → working row appears → a tool row streams in above the working row. The
    /// tail must stay pinned and the jump pill must never appear.
    @Test func sendThenReplyKeepsTheTailAndHidesTheJumpPill() async throws {
        let f = try Fixture(messageCount: 12)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        f.store.draft = "spawn some agent"
        await f.store.send()
        try await waitFor { f.store.sentCount == 1 }
        try await f.layout()
        #expect(f.distanceFromBottom < 2, "after send: \(f.distanceFromBottom)")
        #expect(!jumpVisible(f.host), "pill after send")
        // pi picks it up: running, then a provisional tool row and text.
        var running = Fixture.makeSnapshot(count: 12, running: true, revision: 2)
        f.snapshot = running
        try await waitFor { f.store.snapshot?.revision == 2 }
        try await f.layout()
        #expect(f.distanceFromBottom < 2, "after running: \(f.distanceFromBottom)")
        #expect(!jumpVisible(f.host), "pill after running")
        running.revision = 3
        running.provisional = [
            NativeThreadMessage(entryID: "provisional:tool:c1", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "Run fan-out: 0/32 used")],
                                toolName: "subagent", toolCallID: "c1", argumentsText: "{\"agent\":\"delegate\"}", status: "complete", truncated: false),
            NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant",
                                blocks: [NativeThreadBlock(kind: .text, text: "Spawned a subagent to say hello.")], status: "streaming", truncated: false),
        ]
        f.snapshot = running
        try await waitFor { f.store.snapshot?.revision == 3 }
        try await f.layout()
        #expect(f.distanceFromBottom < 2, "after tool row: \(f.distanceFromBottom)")
        #expect(!jumpVisible(f.host), "pill after tool row")
        // The echo must sit ABOVE the provisional reply, and stay there once persisted.
        let ids = f.store.displayedMessages.map(\.entryID)
        let echo = try #require(ids.firstIndex { $0.hasPrefix("pending:") })
        let tool = try #require(ids.firstIndex { $0 == "provisional:tool:c1" })
        #expect(echo < tool, "echo below reply: \(ids)")
        var persisted = Fixture.makeSnapshot(count: 12, running: true, revision: 4)
        persisted.messages.append(NativeThreadMessage(entryID: "m12", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "spawn some agent")], truncated: false))
        persisted.provisional = running.provisional
        f.snapshot = persisted
        try await waitFor { f.store.snapshot?.revision == 4 }
        try await f.layout()
        #expect(f.store.pending.isEmpty)
        #expect(f.distanceFromBottom < 2, "after persist: \(f.distanceFromBottom)")
        #expect(!jumpVisible(f.host), "pill after persist")
    }

    /// Whether the "Jump to latest" pill is on screen, read from the rendered window. SwiftUI
    /// buttons are not NSViews, so a view-tree search never finds it.
    private func jumpVisible(_ host: NSView) -> Bool {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).contains { $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains("Jump to latest") == true }
    }

    /// Reported: scrolled all the way down while the agent streams, and the jump pill is still
    /// showing. Scroll up a little, stream, then scroll back to the bottom by hand: the view must
    /// re-stick, follow further growth, and drop the pill.
    @Test func scrollingBackToTheBottomWhileStreamingReattaches() async throws {
        let f = try Fixture(messageCount: 24, running: true)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        try await f.wheel(deltaY: 300)
        #expect(f.distanceFromBottom > 100)
        for revision in 2...4 {
            f.snapshot = Fixture.makeSnapshot(count: 24 + (Int(revision) - 1) * 2, running: true, revision: UInt64(revision))
            try await waitFor { f.store.snapshot?.revision == UInt64(revision) }
            try await f.layout()
        }
        #expect(jumpVisible(f.host), "pill should show while detached and streaming")
        // Back down by hand, well past the end (trackpad overshoot clamps at the bottom).
        try await f.wheel(deltaY: -4000)
        try await Task.sleep(for: .milliseconds(500))
        try await f.layout()
        #expect(f.distanceFromBottom <= NativeScrollFollower.threshold, "not at the bottom: \(f.distanceFromBottom)")
        #expect(!jumpVisible(f.host), "pill still showing at the bottom")
        // And the tail follows again.
        f.snapshot = Fixture.makeSnapshot(count: 36, running: true, revision: 5)
        try await waitFor { f.store.snapshot?.revision == 5 }
        try await f.layout()
        #expect(f.distanceFromBottom <= NativeScrollFollower.threshold, "growth after re-stick left the tail: \(f.distanceFromBottom)")
        #expect(!jumpVisible(f.host))
    }

    /// Reported: sending in a long thread scrolled the whole chat off screen. Send from the
    /// bottom of a thread whose snapshot is paged (older history exists) while the agent runs,
    /// with a provisional reply streaming: the view must end at the echo/reply, not in blank space.
    @Test func sendingInALongRunningThreadStaysOnTheContent() async throws {
        let f = try Fixture(messageCount: 60, running: true)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        f.store.draft = "steer: also check the composer"
        await f.store.send()
        try await waitFor { f.store.sentCount == 1 }
        for revision in 2...5 {
            var next = Fixture.makeSnapshot(count: 60 + Int(revision) - 2, running: true, revision: UInt64(revision))
            next.provisional = [NativeThreadMessage(entryID: "provisional:assistant:r", role: "assistant",
                                                    blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "streamed words ", count: revision * 20))],
                                                    status: "streaming", truncated: false)]
            f.snapshot = next
            try await waitFor { f.store.snapshot?.revision == UInt64(revision) }
            try await f.layout()
            let document = f.scrollView.documentView!
            let clip = f.scrollView.contentView
            // Something must be on screen: the visible rect intersects laid-out content.
            let visible = clip.bounds
            let onScreen = document.subviews.flatMap { $0.subviews }.contains { $0.frame.intersects(visible) && $0.frame.height > 4 }
            #expect(onScreen, "no content visible after revision \(revision); offset \(visible.origin.y) doc \(document.bounds.height)")
            #expect(f.distanceFromBottom <= NativeScrollFollower.threshold, "left the tail after revision \(revision): \(f.distanceFromBottom)")
            #expect(f.distanceFromBottom >= -1, "scrolled past the end after revision \(revision): \(f.distanceFromBottom)")
        }
        #expect(!jumpVisible(f.host))
    }

    /// The terminal bridge sends a bounded window; when it cannot overlap the previous one the
    /// store replaces history with a much shorter list. Content shrinks under a pinned view: it
    /// must land on the new tail, never on blank space past the end.
    @Test func historyShrinkingUnderThePinnedViewLandsOnTheTail() async throws {
        let f = try Fixture(messageCount: 60, running: true)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        var shorter = Fixture.makeSnapshot(count: 8, running: true, revision: 2)
        shorter.messages = shorter.messages.enumerated().map { index, message in
            var message = message; message.entryID = "w\(index)"; return message
        }
        f.snapshot = shorter
        try await waitFor { f.store.messages.count == 8 }
        try await f.layout()
        try await Task.sleep(for: .milliseconds(200))
        try await f.layout()
        #expect(f.distanceFromBottom >= -1, "scrolled past the end: \(f.distanceFromBottom)")
        #expect(f.distanceFromBottom <= NativeScrollFollower.threshold, "not on the tail: \(f.distanceFromBottom)")
    }

    /// A terminal agent's bridge sends a bounded, paged window. Sending grows the thread, the
    /// window slides, and history is replaced with a different set of rows (with an older
    /// cursor). The view must end on the echo and reply, never past them.
    @Test func sendingWhileTheHistoryWindowSlidesStaysOnTheContent() async throws {
        let f = try Fixture(messageCount: 40, running: false)
        defer { f.tearDown() }
        f.snapshot.olderCursor = "m0"
        try await waitFor { f.store.ready }
        try await f.layout()
        f.store.draft = "next step please"
        await f.store.send()
        try await waitFor { f.store.sentCount == 1 }
        for revision in 2...4 {
            var next = Fixture.makeSnapshot(count: 44 + revision * 4, running: revision < 4, revision: UInt64(revision))
            // The window slides: drop the oldest rows so the first id no longer overlaps.
            next.messages = Array(next.messages.dropFirst(revision * 6))
            next.messages.append(NativeThreadMessage(entryID: "u-sent", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "next step please")], truncated: false))
            next.olderCursor = next.messages.first?.entryID
            f.snapshot = next
            try await waitFor { f.store.snapshot?.revision == UInt64(revision) }
            try await f.layout()
            try await Task.sleep(for: .milliseconds(150))
            try await f.layout()
            #expect(f.distanceFromBottom >= -1, "scrolled past the end after revision \(revision): \(f.distanceFromBottom)")
            #expect(f.distanceFromBottom <= NativeScrollFollower.threshold, "left the tail after revision \(revision): \(f.distanceFromBottom)")
        }
        #expect(!jumpVisible(f.host))
    }

    @Test func sendingReattachesToTheTailWithoutBlankSpace() async throws {
        let f = try Fixture(messageCount: 30)
        defer { f.tearDown() }
        try await waitFor { f.store.ready }
        try await f.layout()
        // The user had scrolled up to read something.
        try await f.wheel(deltaY: 600)
        #expect(f.distanceFromBottom > 300)
        f.store.draft = "A brand new question from the user"
        await f.store.send()
        try await waitFor { f.store.sentCount == 1 }
        try await f.layout()
        // The echoed turn exists and the view is back at the tail, with no blank space appended.
        #expect(f.store.displayedMessages.last?.entryID.hasPrefix("pending:") == true)
        #expect(f.distanceFromBottom < 2, "sending did not return to the tail: \(f.distanceFromBottom)")
        let document = f.scrollView.documentView!
        let lastVisible = document.subviews.flatMap { $0.subviews }.map { $0.frame.maxY }.max() ?? 0
        #expect(document.bounds.height - lastVisible <= NativeMetrics.turnSpacing * 2 + 13)
    }
}

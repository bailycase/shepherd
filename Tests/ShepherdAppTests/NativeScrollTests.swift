import AppKit
import SwiftUI
import Testing
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
                DesktopNativeThreadView(store: store, active: true, isFocused: false, request: request, showTerminal: {})
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
        // Opens pinned to the tail.
        #expect(f.distanceFromBottom < 2, "expected to open at the bottom, distance \(f.distanceFromBottom)")
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
        #expect(f.distanceFromBottom >= -1 && f.distanceFromBottom < 2)
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

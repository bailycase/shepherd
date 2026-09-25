import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
@testable import ShepherdApp

/// A real `ThreadView` over a long running thread whose host holds a queue (`QueueFixture`), in
/// an off-screen window, with the composer's "Up next" state in the test's hands. Spinners hold
/// still (Reduce Motion), so a settled window draws the same picture twice. Nothing here clicks
/// or presses a key: hover is seeded, handlers are called, events are built and never posted.
@MainActor
final class QueueThread {
    nonisolated static let key = "queue"

    let store = NativeThreadStore()
    let host: QueueFixture
    let state = QueueStackState()
    let commands = ThreadCommandCenter()
    let window: OffscreenWindow
    let size: CGSize
    /// The thread's own scroll view, found before any menu opens.
    private(set) var threadScroll: NSScrollView?

    init(queue: [NativeQueuedMessage] = [], draft: String = "", messages: Int = 40, size: CGSize = CGSize(width: 900, height: 700)) {
        self.size = size
        var snapshot = ComposerThread.snapshot(messages: messages, commands: [])
        snapshot.running = true
        snapshot.supportedActions.append("sendImages")
        host = QueueFixture(snapshot)
        host.change(queue)
        store.draft = draft
        window = OffscreenWindow(size: size, dark: false)
        window.show(ThreadView(store: store, active: true, isFocused: false, request: { [host] in host.answer($0) },
                               commandKey: Self.key, queueState: state)
            .environment(\.threadCommands, commands)
            .environment(\._accessibilityReduceMotion, true))
    }

    /// Loaded, laid out, and drawing the same picture twice in a row.
    func waitUntilReady() async throws {
        try await eventuallyOnMain("the thread to load") { store.ready && state.count == host.queue.count }
        try await settle()
        threadScroll = scrollViews().first
    }

    /// Waits until the whole window draws the same picture for a few polls.
    func settle() async throws {
        let all = CGRect(origin: .zero, size: size)
        var last = FrameTimer.capture(window, all), still = 0
        try await eventuallyOnMain("the window to come to rest", timeout: .seconds(10), poll: .milliseconds(20)) {
            window.layout()
            let now = FrameTimer.capture(window, all)
            still = now == last ? still + 1 : 0
            last = now
            return still >= 5
        }
    }

    /// The host's queue changes (another Mac, or pi taking a message), and the thread pulls it.
    func publish(_ items: [NativeQueuedMessage]) async {
        host.change(items)
        await store.refresh()
        window.layout()
    }

    // MARK: Reading the window

    func scrollViews() -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window.host)
        return found
    }

    /// The composer's measured height, the thread's bottom inset: the card and anything above it.
    var composerInset: CGFloat {
        window.layout()
        return threadScroll?.contentInsets.bottom ?? .nan
    }

    var threadOffset: CGFloat {
        window.layout()
        return threadScroll?.contentView.bounds.origin.y ?? .nan
    }

    /// Whether the thread shows its tail: within the follower's threshold of the bottom.
    var isPinned: Bool {
        window.layout()
        guard let scroll = threadScroll, let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let distance = document.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scroll.contentInsets.bottom)
        return abs(distance) <= NativeScrollFollower.threshold
    }

    /// The composer column's edges.
    var columnLeading: CGFloat {
        let gutter = AppLayout.threadGutter(width: size.width)
        return (size.width - min(AppLayout.threadMaxWidth, size.width - 2 * gutter)) / 2
    }

    var columnTrailing: CGFloat { size.width - columnLeading }

    /// Send's right-click catcher, while Send stands beside an outlined Stop.
    var sendButton: SecondaryClick.Catcher? {
        func find(_ view: NSView) -> SecondaryClick.Catcher? {
            if let catcher = view as? SecondaryClick.Catcher { return catcher }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window.host)
    }

    /// The composer's key monitor (it watches only while the composer has focus; tests hand it
    /// events directly).
    var keyMonitor: ComposerKeyMonitor? {
        func find(_ view: NSView) -> ComposerWindowReader.Reader? {
            if let reader = view as? ComposerWindowReader.Reader { return reader }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window.host)?.monitor
    }

    /// A key press in this window, built but never posted.
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    static var rightClick: NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func close() {
        store.stop()
        window.close()
    }
}

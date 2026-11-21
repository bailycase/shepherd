import AppKit

/// Explicit app writes are logged even if SwiftUI applies them later or drops them.
@MainActor
enum ThreadScrollTrace {
    static func write(_ caller: String, in scroll: @autoclosure () -> NSScrollView?) {
        #if DEBUG
        guard let trace = ScrollTrace.current, let target = scroll(), target === trace.guardian.scrollView() else { return }
        trace.mark(caller)
        #endif
    }

    #if DEBUG
    static func bindPaging(to guardian: ThreadTailGuard, _ prepend: @escaping () -> Void) {
        guard let trace = ScrollTrace.current, trace.guardian === guardian else { return }
        trace.prepend = prepend
    }
    #endif
}

#if DEBUG
import QuartzCore
import ShepherdProtocol
import ShepherdRemote
import SwiftUI

@MainActor
private final class ScrollTrace: NSObject {
    struct Frame: Encodable {
        let timestamp: Double
        let hidden: Bool
        let first: String?
        let rows: [String: Double]
        let offset: Double?
        let events: [Event]
    }

    struct Event: Encodable {
        let caller: String
        var from: Double? = nil
        var to: Double? = nil
        var stack: [String]? = nil
    }

    static weak var current: ScrollTrace?
    let guardian = ThreadTailGuard()
    var scenario = ""
    var shown = true
    var prepend: (() -> Void)?
    private(set) var frames: [String: [Frame]] = [:]
    private(set) var latest: Frame?
    private var events: [Event] = []
    private var nextFrame: CheckedContinuation<Void, Never>?
    private weak var clip: NSClipView?
    private var offset: CGFloat?

    func mark(_ caller: String) { events.append(Event(caller: caller)) }

    func advance(_ count: Int = 1) async {
        for _ in 0..<count { await withCheckedContinuation { nextFrame = $0 } }
    }

    func waitFor(_ name: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ValidationError("timed out waiting for \(name)") }
            await advance()
        }
    }

    @objc func sample(_ link: CADisplayLink) {
        let scroll = guardian.scrollView()
        if clip !== scroll?.contentView {
            if let clip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip) }
            clip = scroll?.contentView
            offset = clip?.bounds.minY
            if let clip {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        let rows = shown ? scroll.map { guardian.scrollTraceRows(in: $0) } ?? [:] : [:]
        let top = scroll?.contentInsets.top ?? 0
        let bottom = (clip?.bounds.height ?? 0) - (scroll?.contentInsets.bottom ?? 0)
        let first = rows.filter { $0.value.maxY > top && $0.value.minY < bottom }.min {
            ($0.value.minY, $0.key) < ($1.value.minY, $1.key)
        }?.key
        let frame = Frame(timestamp: link.timestamp, hidden: !shown, first: first,
                          rows: rows.mapValues { $0.minY - top }, offset: clip.map { Double($0.bounds.minY) }, events: events)
        latest = frame
        if !scenario.isEmpty { frames[scenario, default: []].append(frame) }
        events.removeAll(keepingCapacity: true)
        let waiter = nextFrame
        nextFrame = nil
        waiter?.resume()
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard let from = offset, let to = clip?.bounds.minY, from != to else { return }
        offset = to
        events.append(Event(caller: "NSClipView.bounds", from: from, to: to, stack: Thread.callStackSymbols))
    }
}

private struct ValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Runs before SwiftUI's app/host startup. The offscreen window only mounts fixture-backed ThreadViews.
@MainActor
public enum ThreadScrollValidation {
    public static func main() -> Never {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.bailycase.shepherd.dev",
              let path = env["SHEPHERD_SCROLL_TRACE"], let scratch = env["HOME"],
              env["CFFIXED_USER_HOME"] == scratch,
              env["SHEPHERD_SUPPORT_DIR"] == scratch + "/support",
              URL(fileURLWithPath: scratch).lastPathComponent == "scratch",
              FileManager.default.currentDirectoryPath == scratch,
              path == URL(fileURLWithPath: scratch).deletingLastPathComponent().appendingPathComponent("frames.json").path else {
            print("error: scroll validation requires the Dev bundle and an isolated scratch directory")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let fixture = ScrollFixture()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let url = URL(fileURLWithPath: path)
            do {
                try await fixture.run()
                try encoder.encode(fixture.trace.frames).write(to: url, options: .atomic)
                exit(0)
            } catch {
                try? encoder.encode(fixture.trace.frames).write(to: url, options: .atomic)
                print("error: \(error)")
                exit(2)
            }
        }
        app.run()
        exit(2)
    }
}

@MainActor
private final class ScrollFixture {
    @Observable final class Presentation {
        var active = true
        var resizing = false
    }

    struct Root: View {
        let fixture: ScrollFixture
        let presentation: Presentation

        var body: some View {
            ThreadView(store: fixture.store, active: presentation.active, isFocused: false, request: fixture.request,
                       listModels: { .empty }, retainedInput: fixture.input, retainedTailGuard: fixture.trace.guardian)
                .environment(\.liveResizing, presentation.resizing)
                .environment(\.composerModelDefaults, fixture.defaults)
        }
    }

    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    let trace = ScrollTrace()
    let store = NativeThreadStore()
    let input = ThreadInput()
    let defaults = UserDefaults(suiteName: "shepherd.scroll-validation.\(UUID())")!
    private let presentation = Presentation()
    private lazy var host = DeckHost(rootView: Root(fixture: self, presentation: presentation))
    private let alternate = DeckHost(rootView: Text("Other fixture thread"))
    private let container = NSView()
    private let window = Window(contentRect: NSRect(x: -30_000, y: -30_000, width: 910, height: 640),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    private var pageReply: CheckedContinuation<NativeThreadResult, Never>?
    private let history = (0..<360).flatMap { ScrollFixture.turn($0) }
    private var thread = ScrollFixture.snapshot(messages: [])

    private func request(_ value: NativeThreadRequest) async -> NativeThreadResult {
        guard case let .snapshot(_, before, revision) = value else {
            return .failure(code: "fixture", message: "unexpected request")
        }
        if let before {
            guard before == "user-60", pageReply == nil else {
                return .failure(code: "fixture", message: "unexpected page cursor")
            }
            trace.mark("fixture.pageRequested")
            return await withCheckedContinuation { pageReply = $0 }
        }
        if revision == thread.revision { return .unchanged(piSessionID: thread.piSessionID, generation: thread.generation, revision: thread.revision) }
        return .snapshot(value: thread)
    }

    func run() async throws {
        guard let screen = NSScreen.main else { throw ValidationError("display link requires a WindowServer screen") }
        ScrollTrace.current = trace
        let link = screen.displayLink(target: trace, selector: #selector(ScrollTrace.sample(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate(); window.orderOut(nil); window.contentView = nil }

        thread = Self.snapshot(messages: Array(history.drop(while: { $0.entryID != "user-60" })), older: "user-60")
        thread.running = true
        thread.messages.append(Self.message("stream-user", "user", "Review the remaining cases."))
        thread.provisional = [Self.message("provisional:assistant:1", "assistant", "## Working notes\n\n", status: "streaming")]
        window.contentView = container
        for view in [host as NSView, alternate as NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        alternate.isHidden = true
        window.orderBack(nil)
        try await trace.waitFor("the streaming tail to mount") { self.store.liveRow != nil && self.trace.latest?.first != nil }
        await trace.advance(20)

        trace.scenario = "slow-scroll-streaming"
        await trace.advance()
        for i in 0..<16 {
            try scroll(up: 28)
            await trace.advance()
            trace.mark("fixture.streamChunk")
            thread.provisional[0].blocks[0].text += "Inspecting fixture group \(i). The query returns the rows in ascending order.\n\n"
            await publish()
            await trace.advance(3)
        }
        await trace.advance(24)

        trace.scenario = "flick-and-stop"
        await trace.advance()
        // Script the flick's deltas on the clip, then stop all writes. No posted events or device inertia.
        for delta in [210.0, 160, 110, 70, 45, 20] {
            try scroll(up: delta)
            await trace.advance()
        }
        await trace.advance(40)

        trace.scenario = "mid-history-new-turn"
        await trace.advance()
        try scroll(to: try scrollView().contentView.documentRect.height / 2)
        await trace.advance(25)
        trace.mark("fixture.newTurn")
        thread.messages.append(Self.message("stream-reply", "assistant", thread.provisional[0].blocks[0].text))
        thread.messages.append(Self.message("new-user", "user", "Check the fixture table again."))
        thread.provisional = [Self.message("provisional:assistant:2", "assistant", "I am checking the fixture table.", status: "streaming")]
        await publish()
        try await trace.waitFor("the new turn") { self.store.messages.last?.entryID == "new-user" }
        for _ in 0..<8 {
            try scroll(up: 45)
            await trace.advance(3)
        }
        await trace.advance(24)

        trace.scenario = "page-older-history"
        await trace.advance()
        try scroll(to: -.greatestFiniteMagnitude)
        try await trace.waitFor("the original page's first row") { self.trace.latest?.first == "user-60" }
        // The offscreen scroll doesn't reliably fire SwiftUI's visibility sentinel. Start the
        // same prepend at the visible boundary, including the real anchor capture and restore.
        if pageReply == nil { trace.prepend?() }
        try await trace.waitFor("the older page request") { self.pageReply != nil }
        await trace.advance(12)
        trace.mark("fixture.pageReply")
        pageReply?.resume(returning: .snapshot(value: Self.snapshot(messages: Array(history.prefix(while: { $0.entryID != "user-60" })))))
        pageReply = nil
        try await trace.waitFor("the older page to prepend") { self.store.messages.first?.entryID == "user-0" }
        await trace.advance(55)

        trace.scenario = "window-resize"
        await trace.advance()
        presentation.resizing = true
        for size in [NSSize(width: 660, height: 760), NSSize(width: 1020, height: 510), NSSize(width: 910, height: 640)] {
            trace.mark("fixture.windowResize")
            window.setContentSize(size)
            await trace.advance(12)
        }
        presentation.resizing = false
        await trace.advance(35)

        trace.scenario = "switch-away-back"
        await trace.advance()
        trace.mark("fixture.switchAway")
        trace.shown = false
        presentation.active = false
        alternate.isHidden = false
        hideDeckHost(host, in: container)
        await trace.advance(25)
        thread.revision += 1
        thread.provisional[0].blocks[0].text += "\n\nThe results are ready."
        trace.mark("fixture.switchBack")
        host.isHidden = false
        presentation.active = true
        hideDeckHost(alternate, in: container)
        trace.shown = true
        await trace.advance(55)
        try await trace.waitFor("the thread to be visible after switching back") { self.trace.latest?.first != nil }
    }

    private func publish() async {
        thread.revision += 1
        await store.refresh()
    }

    private func scrollView() throws -> NSScrollView {
        guard let scroll = trace.guardian.scrollView() else { throw ValidationError("missing fixture scroll view") }
        return scroll
    }

    private func scroll(up points: CGFloat) throws {
        try scroll(to: scrollView().contentView.bounds.minY - points)
    }

    private func scroll(to y: CGFloat) throws {
        let scroll = try scrollView()
        let clip = scroll.contentView
        trace.mark("fixture.scrollInput")
        input.readerScrolled(upward: y < clip.bounds.minY)
        trace.guardian.readerMoved()
        var bounds = clip.bounds
        bounds.origin.y = y
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    private static func snapshot(messages: [NativeThreadMessage], older: String? = nil) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "scroll-fixture", generation: "fixture-1", revision: 1, running: false,
            supportedActions: ["send", "abort"], dialogsSupported: true, dialogs: [], messages: messages,
            olderCursor: older, provisional: [], clipped: false, runtime: "rpc")
    }

    private static func message(_ id: String, _ role: String, _ text: String, status: String? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [NativeThreadBlock(kind: .text, text: text)], status: status)
    }

    private static func turn(_ i: Int) -> [NativeThreadMessage] {
        let tools = (0..<(i % 7)).map { j in
            NativeThreadMessage(entryID: "result-\(i)-\(j)", role: "toolResult",
                blocks: [NativeThreadBlock(kind: .text, text: "fixture/Item\(j).swift:9: let example = \(i)")],
                toolName: "read", toolCallID: "call-\(i)-\(j)", argumentsText: "{\"path\":\"fixture/Item\(j).swift\"}", status: "complete")
        }
        let prose = i % 4 == 0 ? """
            ## Fixture notes \(i)

            | Case | Result |
            | --- | --- |
            | Sample A | Present |
            | Sample B | Waiting |

            ```swift
            let samples = (0..<12).filter { $0.isMultiple(of: 2) }
            print(samples)
            ```

            """ + (0..<(4 + i % 17)).map { j in
                "Paragraph \(j): This is a synthetic response about inspecting sample records locally. Look at the case table before making a decision about the next group."
            }.joined(separator: "\n\n") : "Fixture group \(i) checked. The results match the expected order."
        return [message("user-\(i)", "user", "Inspect sample group \(i).")]
            + tools + [message("reply-\(i)", "assistant", prose)]
    }
}
#endif

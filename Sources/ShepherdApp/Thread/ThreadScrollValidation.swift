import AppKit
import ShepherdUI

/// Explicit app writes are logged even if SwiftUI applies them later or drops them.
@MainActor
enum ThreadScrollTrace {
    static func write(_ actor: StaticString, _ caller: String, in scroll: @autoclosure () -> NSScrollView?,
                      target: String? = nil) {
        SHRenderProbe.scrollEvent(actor, caller, from: scroll(), target: target)
    }
}

import ShepherdRemote
import SwiftUI

extension ScrollPhase {
    var intentPhase: ScrollIntent.Phase {
        switch self {
        case .tracking, .interacting: .touching
        case .decelerating: .coasting
        case .animating: .animating
        default: .idle
        }
    }
}

extension NSEvent.Phase {
    var intentPhase: ScrollIntent.WheelPhase {
        if isEmpty { return .absent }
        return intersection([.began, .changed, .stationary]).isEmpty ? .inactive : .active
    }
}

#if DEBUG
import QuartzCore
import ShepherdCore
import ShepherdProtocol

@MainActor
final class MacScrollValidationTrace: NSObject {
    struct Frame: Encodable {
        let timestamp: Double
        let refreshInterval: Double
        let hidden: Bool
        let first: String?
        let rows: [String: Double]
        let visibleRows: [String]
        let offset: Double?
        let documentHeight: Double?
        let streamingRowHeight: Double?
        let clipSize: [Double]?
        let following: Bool
        let distance: Double
        let events: [Event]
        let motion: String
        let intent: ScrollIntent.State
    }

    struct Event: Encodable {
        let caller: String
        var from: Double? = nil
        var to: Double? = nil
        var stack: [String]? = nil
        var scrollDelta: Double? = nil
        var detail: String? = nil
        var kind: String? = nil
        var motion: String? = nil
        var anchor: String? = nil
        var target: String? = nil
        var following: Bool? = nil
    }

    static weak var current: MacScrollValidationTrace?
    let guardian = ThreadTailGuard()
    var scenario = "" {
        didSet { FileHandle.standardError.write(Data("scroll fixture: \(scenario)\n".utf8)) }
    }
    var wheel: ((CGFloat) -> Void)?
    var phase: ((ScrollPhase, ScrollPhase, CGFloat) -> Void)?
    var historyVisibility: ((Bool) -> Void)?
    var deckPage: ((AgentLayoutModel) -> AnyView)?
    var streamingRowID: String?
    private(set) var frames: [String: [Frame]] = [:]
    private(set) var latest: Frame?
    private var events: [Event] = []
    private var nextFrame: CheckedContinuation<Void, Never>?
    private weak var clip: NSClipView?
    private var offset: CGFloat?
    private var phaseState = ScrollPhase.idle
    var wheelUntil = ContinuousClock.now
    private var scriptedWrite = false
    private var intent = ScrollIntent()

    var pinIntent: ScrollIntent.State {
        var copy = intent
        return copy.sampleMac(phase: phaseState.intentPhase, now: .now,
                              leftMouseDown: copy.physicalScrollerHeld && NSEvent.pressedMouseButtons & 1 != 0)
    }

    func phaseChanged(to phase: ScrollPhase) {
        intent.phaseChanged(from: phaseState.intentPhase, to: phase.intentPhase, now: .now)
        phaseState = phase
    }

    func wheelInput(phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [], moved: Bool) {
        intent.wheelInput(phase: phase.intentPhase, momentum: momentum.intentPhase, moved: moved, now: .now)
    }

    func observe(_ event: NSEvent, responder: NSResponder?) {
        guard let scroll = guardian.scrollView(), let window = scroll.window,
              event.window === window, !scroll.isHiddenOrHasHiddenAncestor else { return }
        switch event.type {
        case .keyDown:
            guard let key = event.charactersIgnoringModifiers?.utf16.first else { return }
            keyInput(Int(key), modifiers: event.modifierFlags, responder: responder, in: scroll)
        case .scrollWheel:
            if intent.wheelInFlight(at: .now) || scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) {
                wheelInput(phase: event.phase, momentum: event.momentumPhase, moved: event.scrollingDeltaY != 0)
            }
        case .leftMouseDown:
            scrollerGrab(at: event.locationInWindow, in: scroll, physical: true)
        case .leftMouseUp:
            scrollerRelease()
        default: break
        }
    }

    func keyInput(_ key: Int, modifiers: NSEvent.ModifierFlags, responder: NSResponder?, in scroll: NSScrollView) {
        guard !modifiers.contains(.option), !modifiers.contains(.control),
              !modifiers.contains(.command) || [NSUpArrowFunctionKey, NSDownArrowFunctionKey].contains(key) else { return }
        switch key {
        case NSPageUpFunctionKey, NSPageDownFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey,
             NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSHomeFunctionKey, NSEndFunctionKey, 32:
            break
        default: return
        }
        if let view = responder as? NSView {
            guard (view === scroll || view.isDescendant(of: scroll)), !(view is NSTextView), !(view is NSControl) else { return }
        } else if responder !== scroll.window { return }
        intent.keyInput(at: .now)
    }

    func scrollerGrab(at point: NSPoint, in scroll: NSScrollView, physical: Bool) {
        guard let scroller = scroll.verticalScroller, scroller.isEnabled,
              !scroller.isHiddenOrHasHiddenAncestor, scroller.testPart(point) == .knob else { return }
        intent.scrollerGrab(physical: physical)
    }

    func scrollerRelease() { intent.scrollerRelease() }

    private func sampleIntent(visible: Bool) -> ScrollIntent.State {
        guard visible else {
            intent = ScrollIntent()
            phaseState = .idle
            return .idle
        }
        return intent.sampleMac(phase: phaseState.intentPhase, now: .now,
                                leftMouseDown: intent.physicalScrollerHeld && NSEvent.pressedMouseButtons & 1 != 0)
    }

    private var motion: String {
        switch phaseState {
        case .tracking, .interacting: "touching"
        case .decelerating: "coasting"
        case .animating: "programmatic"
        default: .now < wheelUntil ? "wheel" : "idle"
        }
    }

    func record(_ event: SHRenderProbe.ScrollEvent, source: AnyObject?) {
        if let source, source !== guardian, source !== guardian.scrollView() { return }
        events.append(Event(caller: event.caller, detail: event.detail, kind: event.kind, motion: motion,
                            anchor: latest?.first, target: event.target, following: guardian.following))
    }

    func mark(_ caller: String) { events.append(Event(caller: caller)) }

    func scrollInput(_ delta: CGFloat, write: () -> Void) {
        events.append(Event(caller: "fixture.scrollInput", scrollDelta: delta))
        SHRenderProbe.scrollEvent("thread.write.fixture", "fixture.clip.scroll", from: guardian, kind: "fixture")
        scriptedWrite = true
        defer { scriptedWrite = false }
        write()
    }

    /// Start the settle window once a frame has sampled the last action, even if that sample stalls.
    func settle() async {
        await advance()
        let deadline = ContinuousClock.now + .milliseconds(850)
        repeat { await advance() } while ContinuousClock.now < deadline
    }

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
        let hidden = scroll?.isHiddenOrHasHiddenAncestor == true
        let rows = hidden ? [:] : scroll.map { guardian.scrollTraceRows(in: $0) } ?? [:]
        let top = scroll?.contentInsets.top ?? 0
        let bottom = (clip?.bounds.height ?? 0) - (scroll?.contentInsets.bottom ?? 0)
        let visible = rows.filter { $0.value.maxY > top && $0.value.minY < bottom }
        let sampledIntent = sampleIntent(visible: scroll != nil && !hidden)
        let frame = Frame(timestamp: CACurrentMediaTime(), refreshInterval: link.targetTimestamp - link.timestamp,
                          hidden: hidden, first: visible.min {
                              ($0.value.minY, $0.key) < ($1.value.minY, $1.key)
                          }?.key, rows: rows.mapValues { $0.minY - top }, visibleRows: visible.keys.sorted(),
                          offset: clip.map { Double($0.bounds.minY) }, documentHeight: clip.map { Double($0.documentRect.height) },
                          streamingRowHeight: streamingRowID.flatMap { rows[$0] }.map { Double($0.height) },
                          clipSize: clip.map { [Double($0.bounds.width), Double($0.bounds.height)] },
                          following: guardian.following, distance: guardian.distance, events: events, motion: motion,
                          intent: sampledIntent)
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
        events.append(Event(caller: "NSClipView.bounds", from: from, to: to, stack: Thread.callStackSymbols,
                            detail: scriptedWrite ? "fixture.clip.scroll" : nil, motion: motion, anchor: latest?.first))
    }
}

private struct ValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct IntentMismatch: Error, CustomStringConvertible {
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
                exit(error is IntentMismatch ? 4 : 2)
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

        var body: some View {
            AgentLayoutDeck(scrollFixtureModels: fixture.models)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.liveResizing, fixture.presentation.resizing)
                .environment(\.composerModelDefaults, fixture.defaults)
                .environment(\.threadCommands, fixture.commands)
        }
    }

    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    let trace = MacScrollValidationTrace()
    let store = NativeThreadStore()
    let input = ThreadInput()
    private let commands = ThreadCommandCenter()
    private static let commandKey = "scroll-fixture"
    let defaults = UserDefaults(suiteName: "shepherd.scroll-validation.\(UUID())")!
    private let presentation = Presentation()
    private let tabs: [ShepherdCore.Tab] = {
        let space = SpaceID()
        return (0..<2).map { ShepherdCore.Tab(spaceID: space, order: $0, layout: .leaf(LeafPane(cwd: "/tmp", isReview: true))) }
    }()
    private var models: [AgentLayoutModel] {
        tabs.enumerated().map { index, tab in
            AgentLayoutModel(tab: tab, isVisible: index == (presentation.active ? 0 : 1), thread: nil,
                             focusedPaneID: nil, inspectingRunID: nil, review: nil)
        }
    }
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
        MacScrollValidationTrace.current = trace
        SHRenderProbe.scrollEvents = { [weak trace] event, source in trace?.record(event, source: source) }
        NativeThreadStore.scrollTraceParsed = { [weak self] store, id in
            guard let self, store === self.store else { return }
            SHRenderProbe.scrollEvent("thread.write.L8", "markdown.parseLanded", from: trace.guardian, target: id, kind: "layout")
        }
        SHRenderProbe.disabledScrollAnchor = ProcessInfo.processInfo.environment["SHEPHERD_SCROLL_ANCHOR_OFF"]
        let link = screen.displayLink(target: trace, selector: #selector(MacScrollValidationTrace.sample(_:)))
        link.add(to: .main, forMode: .common)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak trace] event in
            trace?.observe(event, responder: event.window?.firstResponder)
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            link.invalidate(); window.orderOut(nil); window.contentView = nil
            SHRenderProbe.scrollEvents = nil
            NativeThreadStore.scrollTraceParsed = nil
            SHRenderProbe.disabledScrollAnchor = nil
        }

        thread = Self.snapshot(messages: Array(history.drop(while: { $0.entryID != "user-60" })), older: "user-60")
        thread.running = true
        thread.messages.append(Self.message("stream-user", "user", "Review the remaining cases."))
        thread.provisional = [Self.message("provisional:assistant:1", "assistant", "## Working notes\n\n", status: "streaming")]
        trace.deckPage = { [unowned self] model in
            if model.tab.id == tabs[0].id {
                return AnyView(ThreadView(store: store, active: model.isVisible, isFocused: false, request: request,
                                          commandKey: Self.commandKey, listModels: { .empty }, retainedInput: input,
                                          retainedTailGuard: trace.guardian))
            }
            return AnyView(Color.clear)
        }
        window.contentView = NSHostingView(rootView: Root(fixture: self))
        window.orderBack(nil)
        try await trace.waitFor("the streaming tail to mount") { self.store.liveRow != nil && self.trace.latest?.first != nil }
        trace.streamingRowID = store.liveRow?.id
        await trace.advance()
        // The first live layout replaces the stack's initial height estimate. Warm it before measuring.
        try await streamChunk(0, marker: "fixture.warmupChunk")
        await trace.settle()

        trace.scenario = "slow-scroll-streaming"
        await trace.advance()
        try await trace.waitFor("the reader inside the sticky band") {
            self.trace.latest.map { $0.following && $0.distance <= ThreadTailGuard.band } == true
        }
        try await streamChunk(1, marker: "fixture.stickyChunk")
        // The lazy stack can rebase its height and consume a drag while its old bottom anchor
        // is still installed. Try again only until layout confirms the reader is out of the band.
        for _ in 0..<12 {
            try phase(from: .idle, to: .interacting)
            try scroll(up: 140, wheel: false, endDrag: true)
            await trace.advance(3)
            if !trace.guardian.following, trace.guardian.distance > ThreadTailGuard.band { break }
        }
        guard !trace.guardian.following, trace.guardian.distance > ThreadTailGuard.band else {
            throw ValidationError("scripted drag did not detach the reader before streaming")
        }
        try await streamChunk(2, marker: "fixture.streamChunk")
        for i in 3...17 {
            try scroll(up: 28)
            await trace.advance()
            try await streamChunk(i, marker: "fixture.streamChunk")
        }
        await trace.settle()

        // The flick starts at the tail regardless of where the streaming drag ended.
        if !trace.guardian.following || trace.guardian.distance > ThreadTailGuard.slack {
            trace.scenario = ""
            commands.send(.nextTurn, to: Self.commandKey)
            try await trace.waitFor("the flick to start at the tail") {
                self.trace.guardian.following && self.trace.guardian.distance <= ThreadTailGuard.slack
            }
            await trace.settle()
        }
        trace.scenario = "flick-and-stop"
        await trace.advance()
        // Drive the production phase handler without posting events or relying on device inertia.
        try phase(from: .idle, to: .interacting)
        for delta in [210.0, 160, 110] {
            try scroll(up: delta, wheel: false)
            await trace.advance()
            try requireIntent(.touching)
        }
        try phase(from: .interacting, to: .decelerating)
        for delta in [70.0, 45, 20] {
            try scroll(up: delta, wheel: false)
            await trace.advance()
            try requireIntent(.coasting)
        }
        try phase(from: .decelerating, to: .idle)
        await trace.settle()
        try requireIntent(.idle)

        trace.scenario = "mid-history-new-turn"
        await trace.advance()
        try scroll(to: try scrollView().contentView.documentRect.height / 2)
        await trace.settle()
        let oldHeight = trace.latest?.documentHeight
        trace.mark("fixture.newTurn")
        thread.messages.append(Self.message("stream-reply", "assistant", thread.provisional[0].blocks[0].text))
        thread.messages.append(Self.message("new-user", "user", "Check the fixture table again."))
        thread.provisional = [Self.message("provisional:assistant:2", "assistant", "I am checking the fixture table.", status: "streaming")]
        await publish()
        try await trace.waitFor("the new turn to change the document height") {
            self.store.messages.last?.entryID == "new-user" && self.trace.latest?.documentHeight != oldHeight
        }
        for _ in 0..<8 {
            try scroll(up: 45)
            await trace.advance(3)
        }
        await trace.settle()

        trace.scenario = "page-older-history"
        await trace.advance()
        try scroll(to: -.greatestFiniteMagnitude)
        try await trace.waitFor("the original page's first row") { self.trace.latest?.first == "user-60" }
        // Give the native sentinel time to fire. If there is no request, feed the measured
        // boundary to its handler. This exercises paging but does not prove sentinel delivery.
        await trace.settle()
        if pageReply == nil {
            guard trace.latest?.first == "user-60", let visibility = trace.historyVisibility else {
                throw ValidationError("missing history sentinel at the older boundary")
            }
            trace.mark("fixture.historyVisibilityFallback")
            visibility(true)
        }
        try await trace.waitFor("the older page request") { self.pageReply != nil }
        await trace.advance()
        trace.mark("fixture.pageReply")
        pageReply?.resume(returning: .snapshot(value: Self.snapshot(messages: Array(history.prefix(while: { $0.entryID != "user-60" })))))
        pageReply = nil
        try await trace.waitFor("the older page to prepend") { self.store.messages.first?.entryID == "user-0" }
        await trace.settle()

        trace.scenario = "window-resize"
        await trace.advance()
        presentation.resizing = true
        for size in [NSSize(width: 660, height: 760), NSSize(width: 1020, height: 510), NSSize(width: 910, height: 640)] {
            let oldSize = trace.latest?.clipSize
            trace.mark("fixture.windowResize")
            window.setContentSize(size)
            try await trace.waitFor("the clip to resize") { self.trace.latest?.clipSize != oldSize }
            await trace.settle()
        }
        presentation.resizing = false
        await trace.settle()

        trace.scenario = "switch-away-back"
        await trace.advance()
        let retained = try scrollView()
        trace.mark("fixture.switchAway")
        presentation.active = false
        try await trace.waitFor("the deck to hide the thread") { self.trace.latest?.hidden == true }
        await trace.settle()
        trace.mark("fixture.switchBack")
        presentation.active = true
        try await trace.waitFor("the thread to be visible after switching back") { self.trace.latest?.first != nil }
        guard try scrollView() === retained else { throw ValidationError("deck remounted the thread scroll view") }
        await trace.settle()
        try await captureOtherInputs(in: retained)
        try await wheelWalkToTop(in: retained)

        // Keep this out of the motion baseline: the original switch retains all of its rows.
        trace.scenario = "released-thread"
        presentation.active = false
        try await trace.waitFor("the retained transcript to hide") { self.trace.latest?.hidden == true }
        store.releaseTranscript(keepingLastScreen: true)
        guard store.transcriptReleased else { throw ValidationError("fixture did not release its hidden rows") }
        await trace.settle()
    }

    private func requireIntent(_ expected: ScrollIntent.State) throws {
        guard trace.latest?.intent == expected else {
            throw IntentMismatch("\(trace.scenario): expected \(expected), saw \(String(describing: trace.latest?.intent))")
        }
    }

    private func captureOtherInputs(in scroll: NSScrollView) async throws {
        trace.scenario = "key-paging"
        await trace.advance()
        trace.mark("fixture.pageDown")
        trace.keyInput(NSPageDownFunctionKey, modifiers: [.function], responder: scroll, in: scroll)
        // AppKit routes the action through the key window. Keep this test offscreen and use
        // the clip's measured page instead.
        let previous = scroll.contentView.bounds.minY
        try self.scroll(to: previous + scroll.contentView.bounds.height, wheel: false)
        // layoutSubtreeIfNeeded can itself sample the key; check that frame, not a later one.
        func pageFrame() -> MacScrollValidationTrace.Frame? {
            trace.frames[trace.scenario]?.first { frame in frame.events.contains { $0.caller == "fixture.pageDown" } }
        }
        try await trace.waitFor("the page down frame") { pageFrame() != nil }
        guard let frame = pageFrame(), (frame.offset ?? previous) > previous else {
            throw ValidationError("page down did not move the viewport")
        }
        guard frame.intent == .touching else {
            throw IntentMismatch("key-paging: expected touching, saw \(frame.intent)")
        }
        try phase(from: .idle, to: .animating)
        await trace.advance()
        try requireIntent(.coasting)
        try phase(from: .animating, to: .idle)
        await trace.settle()
        try requireIntent(.idle)

        trace.scenario = "scroller-drag"
        // Use a visible native knob in the scratch window, independent of the OS scrollbar preference.
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.tile()
        await trace.settle()
        guard let scroller = scroll.verticalScroller else { throw ValidationError("missing vertical scroller") }
        let knob = scroller.rect(for: .knob)
        let location = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        trace.mark("fixture.scrollerGrab")
        trace.scrollerGrab(at: location, in: scroll, physical: false)
        // Run the native hit-test without posting input or entering AppKit's tracking loop.
        let before = scroll.contentView.bounds.minY
        try self.scroll(to: before + 240, wheel: false)
        await trace.advance(2)
        guard trace.latest.map({ ($0.offset ?? before) > before }) == true else {
            throw ValidationError("scroller fixture did not move the viewport")
        }
        try requireIntent(.touching)
        trace.mark("fixture.scrollerRelease")
        trace.scrollerRelease()
        await trace.settle()
        try requireIntent(.idle)

        trace.mark("fixture.scrollerGrabBeforeHide")
        trace.scrollerGrab(at: location, in: scroll, physical: false)
        await trace.advance()
        try requireIntent(.touching)
        // Leave both sources of touching active across the visibility flip, without posting input.
        trace.phaseChanged(to: .interacting)
        presentation.active = false
        try await trace.waitFor("the thread to hide with the scroller held") { self.trace.latest?.hidden == true }
        presentation.active = true
        try await trace.waitFor("the thread to show after hiding with the scroller held") { self.trace.latest?.first != nil }
        try requireIntent(.idle)
    }

    private func wheelWalkToTop(in scroll: NSScrollView) async throws {
        trace.scenario = "wheel-walk-to-top"
        await trace.advance()
        let clip = scroll.contentView
        let step = (clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom) / 2
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
            let bounds = clip.bounds
            let next = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: -step)).minY
            if next >= bounds.minY {
                trace.mark("fixture.wheelTopReached")
                break
            }
            guard ContinuousClock.now < deadline else { break }
            try self.scroll(up: step)
            await trace.advance()
        }
        await trace.settle()
    }

    private func streamChunk(_ index: Int, marker: String) async throws {
        let oldHeight = trace.latest?.documentHeight
        guard let oldRowHeight = trace.latest?.streamingRowHeight else { throw ValidationError("missing streaming row") }
        trace.mark(marker)
        thread.provisional[0].blocks[0].text += "Inspecting fixture group \(index). The query returns the rows in ascending order.\n\n"
        await publish()
        try await trace.waitFor("stream chunk \(index) to grow the row and change the document height") {
            (self.trace.latest?.streamingRowHeight ?? 0) > oldRowHeight && self.trace.latest?.documentHeight != oldHeight
        }
        await trace.advance(2)
    }

    private func phase(from old: ScrollPhase, to phase: ScrollPhase, distance: CGFloat? = nil) throws {
        guard let handler = trace.phase else { throw ValidationError("missing scroll phase handler") }
        handler(old, phase, distance ?? trace.guardian.distance)
        trace.mark("fixture.phase.\(phase)")
    }

    private func publish() async {
        thread.revision += 1
        await store.refresh()
    }

    private func scrollView() throws -> NSScrollView {
        guard let scroll = trace.guardian.scrollView() else { throw ValidationError("missing fixture scroll view") }
        return scroll
    }

    private func scroll(up points: CGFloat, wheel: Bool = true, endDrag: Bool = false) throws {
        try scroll(to: scrollView().contentView.bounds.minY - points, wheel: wheel, endDrag: endDrag)
    }

    private func scroll(to y: CGFloat, wheel: Bool = true, endDrag: Bool = false) throws {
        let scroll = try scrollView()
        let clip = scroll.contentView
        if wheel {
            guard let wheelHandler = trace.wheel else { throw ValidationError("missing wheel intent handler") }
            let delta = clip.bounds.minY - y
            trace.wheelInput(moved: delta != 0)
            wheelHandler(delta)
        }
        var bounds = clip.bounds
        bounds.origin.y = y
        let target = clip.constrainBoundsRect(bounds).origin
        trace.scrollInput(target.y - clip.bounds.minY) { clip.scroll(to: target) }
        if endDrag {
            let distance = clip.documentRect.maxY - clip.bounds.maxY + scroll.contentInsets.bottom
            try phase(from: .interacting, to: .idle, distance: distance)
        }
        scroll.reflectScrolledClipView(clip)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
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

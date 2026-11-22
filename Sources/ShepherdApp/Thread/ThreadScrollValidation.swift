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

#if DEBUG
import QuartzCore
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import SwiftUI

private extension ScrollPhase {
    var intentPhase: ScrollIntent.Phase {
        switch self {
        case .tracking, .interacting: .touching
        case .decelerating: .coasting
        case .animating: .animating
        default: .idle
        }
    }
}

private extension NSEvent.Phase {
    var intentPhase: ScrollIntent.WheelPhase {
        if isEmpty { return .absent }
        return intersection([.began, .changed, .stationary]).isEmpty ? .inactive : .active
    }
}

@MainActor
final class MacScrollValidationTrace: NSObject {
    static func readingCoverage(of row: CGRect, top: CGFloat, bottom: CGFloat) -> [Double]? {
        let start = max(top, row.minY)
        let end = min(bottom, row.maxY + AppLayout.turnSpacing)
        return start < end ? [start - top, end - top] : nil
    }

    struct Frame: Encodable {
        let timestamp: Double
        let refreshInterval: Double
        let hidden: Bool
        let first: String?
        let rows: [String: Double]
        let visibleRows: [String]
        let readingHeight: Double?
        let readingCoverage: [[Double]]
        let eagerTail: String?
        let seamGap: Double?
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
    weak var measuredHistory: ThreadMeasuredHistory?
    var deckPage: ((AgentLayoutModel) -> AnyView)?
    var streamingRowID: String?
    var historyBoundary: (() -> (lazy: String, eager: String)?)?
    private(set) var frames: [String: [Frame]] = [:]
    private(set) var latest: Frame?
    private var events: [Event] = []
    private var nextFrame: CheckedContinuation<Void, Never>?
    private weak var clip: NSClipView?
    private var offset: CGFloat?
    private var phaseState = ScrollPhase.idle
    var wheelUntil = ContinuousClock.now
    private var scriptedWrite = false
    fileprivate var wheelLayoutRunning = false
    fileprivate var wheelTraceTimes: (inLayout: UInt64, outside: UInt64) = (0, 0)
    private var intent = ScrollIntent()
    var physicalScrollerHeld: Bool { intent.physicalScrollerHeld }

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
        // Insets exclude the header margin and floating composer. The transcript ends with
        // a 1 pt bottom sentinel. Coverage measures mounted rows in an offscreen window, not drawn pixels.
        let readingBottom = min(bottom, clip.map { $0.documentRect.maxY - $0.bounds.minY - 1 } ?? bottom)
        let spacing = AppLayout.turnSpacing
        let coverage = rows.values.compactMap { Self.readingCoverage(of: $0, top: top, bottom: readingBottom) }
        let boundary = historyBoundary?()
        let seamGap = boundary.flatMap { ids in
            rows[ids.lazy].flatMap { last in rows[ids.eager].map { Double($0.minY - last.maxY - spacing) } }
        }
        let sampledIntent = sampleIntent(visible: scroll != nil && !hidden)
        let frame = Frame(timestamp: CACurrentMediaTime(), refreshInterval: link.targetTimestamp - link.timestamp,
                          hidden: hidden, first: visible.min {
                              ($0.value.minY, $0.key) < ($1.value.minY, $1.key)
                          }?.key, rows: rows.mapValues { $0.minY - top }, visibleRows: visible.keys.sorted(),
                          readingHeight: clip != nil && !hidden ? max(0, readingBottom - top) : nil,
                          readingCoverage: coverage, eagerTail: boundary?.eager, seamGap: seamGap,
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
        let start = ThreadScrollValidation.timingWheel ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : nil
        let inLayout = wheelLayoutRunning
        defer {
            if let start {
                let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
                if inLayout { wheelTraceTimes.inLayout += elapsed }
                else { wheelTraceTimes.outside += elapsed }
            }
        }
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
    private(set) static var measuredHistory = false
    fileprivate(set) static var timingWheel = false

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
        measuredHistory = env["SHEPHERD_SCROLL_MEASURED_HISTORY"] == "1"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let fixtures = [ScrollFixture(), ScrollFixture(), ScrollFixture()]
            @MainActor func frames() -> [String: [MacScrollValidationTrace.Frame]] {
                fixtures.reduce(into: [:]) { $0.merge($1.trace.frames, uniquingKeysWith: { _, new in new }) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let url = URL(fileURLWithPath: path)
            do {
                let pagingOnly = env["SHEPHERD_SCROLL_PAGING_ONLY"] == "1"
                let wheelTurns = env["SHEPHERD_SCROLL_WHEEL_TURNS"].flatMap(Int.init)
                try await fixtures[0].run(pagingOnly: pagingOnly, wheelTurns: wheelTurns)
                if !pagingOnly && wheelTurns == nil {
                    try await fixtures[1].run(crossing: .slow)
                    try await fixtures[2].run(crossing: .flick)
                }
                try encoder.encode(frames()).write(to: url, options: .atomic)
                exit(0)
            } catch {
                try? encoder.encode(frames()).write(to: url, options: .atomic)
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
    private var wheelLayoutTimes: (window: UInt64, subtree: UInt64) = (0, 0)

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

    enum Crossing { case slow, flick }

    func run(crossing: Crossing? = nil, pagingOnly: Bool = false, wheelTurns: Int? = nil) async throws {
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

        if let wheelTurns {
            guard (1...360).contains(wheelTurns) else { throw ValidationError("wheel turns must be in 1...360") }
            thread = Self.snapshot(messages: Array(history.drop(while: { $0.entryID != "user-\(360 - wheelTurns)" })))
        } else {
            thread = Self.snapshot(messages: Array(history.drop(while: { $0.entryID != "user-60" })), older: "user-60")
        }
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
        let mountStart = CACurrentMediaTime()
        window.contentView = NSHostingView(rootView: Root(fixture: self))
        window.orderBack(nil)
        try await trace.waitFor("the streaming tail to mount") { self.store.liveRow != nil && self.trace.latest?.first != nil }
        if crossing == nil { recordMount(since: mountStart) }
        trace.streamingRowID = store.liveRow?.id
        trace.historyBoundary = { [weak store] in
            guard let store, let eager = store.drawnEagerRows, eager > 0, eager < store.rows.count else { return nil }
            let split = store.rows.count - eager
            return (store.rows[split - 1].id, store.rows[split].id)
        }
        await trace.advance()
        // The first live layout replaces the stack's initial height estimate. Warm it before measuring.
        try await streamChunk(0, marker: "fixture.warmupChunk")
        await trace.settle()
        if wheelTurns != nil {
            try await wheelWalkToTop(in: scrollView(), timeLimit: .seconds(45))
            return
        }
        if crossing == nil { trace.scenario = "slow-scroll-streaming" }
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
        if let crossing {
            try await crossBand(crossing)
            return
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
        let destination = try scrollView().contentView.documentRect.height / 2
        if let measuredHistory = trace.measuredHistory {
            try measuredHistory.landJump { try scroll(to: destination) }
        } else {
            try scroll(to: destination)
        }
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
        if pagingOnly { return }

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

    private func recordMount(since start: Double) {
        let milliseconds = (CACurrentMediaTime() - start) * 1_000
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? String(info.phys_footprint) : "unavailable"
        let historyRows = store.rows.count - (store.drawnEagerRows ?? 0)
        let mounted = trace.latest?.rows.count ?? 0
        print("mount: \(milliseconds) ms, \(footprint) footprint bytes, \(historyRows) history rows, \(mounted) row markers")
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

    private func wheelWalkToTop(in scroll: NSScrollView, timeLimit: Duration = .seconds(8)) async throws {
        trace.scenario = "wheel-walk-to-top"
        await trace.advance()
        let clip = scroll.contentView
        let step = (clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom) / 2
        let counters = ["thread.rowBuilder", "thread.wheel.publishWindow", "thread.wheel.windowMove",
                        "thread.wheel.commit", "thread.wheel.rowMarkerLayout", "thread.wheel.finderFrameSize"]
        FileHandle.standardError.write(Data("wheel timing: \(store.rows.count - (store.drawnEagerRows ?? 0)) history rows\n".utf8))
        SHRenderProbe.start()
        ThreadScrollValidation.timingWheel = true
        var costs: [String] = []
        defer {
            ThreadScrollValidation.timingWheel = false
            SHRenderProbe.stop()
            let header = (["wheel-step", "cpu-ms", "window-layout-ms", "subtree-layout-ms",
                           "trace-in-layout-ms", "trace-outside-ms"] + counters).joined(separator: ",")
            FileHandle.standardError.write(Data((header + "\n" + costs.joined(separator: "\n") + "\n").utf8))
        }
        let deadline = ContinuousClock.now + timeLimit
        while true {
            let bounds = clip.bounds
            let next = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: -step)).minY
            if next >= bounds.minY {
                trace.mark("fixture.wheelTopReached")
                break
            }
            guard ContinuousClock.now < deadline else { break }
            let before = counters.map(SHRenderProbe.count)
            trace.wheelTraceTimes = (0, 0)
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            try self.scroll(up: step)
            let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
            let times = [elapsed, wheelLayoutTimes.window, wheelLayoutTimes.subtree,
                         trace.wheelTraceTimes.inLayout, trace.wheelTraceTimes.outside].map { String(Double($0) / 1_000_000) }
            let counts = zip(counters.map(SHRenderProbe.count), before).map { String($0 - $1) }
            costs.append(([String(costs.count + 1)] + times + counts).joined(separator: ","))
            await trace.advance()
        }
        await trace.settle()
    }

    private func crossBand(_ crossing: Crossing) async throws {
        try await trace.waitFor("the crossing to start at the tail") {
            self.trace.guardian.following && self.trace.guardian.distance <= ThreadTailGuard.slack
        }
        trace.scenario = crossing == .flick ? "cross-band-flick" : "cross-band-slow"
        await trace.advance()
        let viewport = try scrollView().contentView.bounds.height
        func inHistory(from distance: CGFloat = 0) -> Bool {
            guard let drawn = store.drawnEagerRows, let frame = trace.latest else { return false }
            return !frame.following && frame.distance - distance >= 5 * viewport
                && store.rows.dropLast(drawn).contains { frame.visibleRows.contains($0.id) }
        }
        if crossing == .flick {
            for index in 0..<2 {
                try phase(from: .idle, to: .interacting)
                // Start inside a viewport so the first departure can exercise the hold.
                for delta in [140.0, 280, 400] {
                    try scroll(up: delta, wheel: false)
                    await trace.advance()
                }
                try phase(from: .interacting, to: .decelerating)
                for step in 0..<(index == 0 ? 40 : 4) {
                    try scroll(up: max(0.35, 0.8 - 0.04 * CGFloat(step)) * viewport, wheel: false)
                    await trace.advance()
                    if step == 2 { try await crossingChunk(60 + index) }
                    if index == 0 && step >= 8 && inHistory() { break }
                }
                if index == 0 {
                    guard inHistory() else { throw ValidationError("the first flick did not reach lazy history") }
                    trace.mark("fixture.crossedIntoHistory")
                }
                try phase(from: .decelerating, to: .idle)
                await trace.settle()
            }
        } else {
            // A height re-estimate can swallow the drag and leave the viewport at distance 0
            // even after the phase callback reports detached. Require actual departure.
            for _ in 0..<20 {
                try phase(from: .idle, to: .interacting)
                try scroll(up: 140, wheel: false, endDrag: true)
                await trace.advance(3)
                if !trace.guardian.following, trace.guardian.distance > ThreadTailGuard.band { break }
            }
            guard !trace.guardian.following, trace.guardian.distance > ThreadTailGuard.band else {
                throw ValidationError("the crossing did not leave the tail band")
            }
            let start = trace.guardian.distance
            for step in 0..<60 {
                try scroll(up: viewport / 3)
                await trace.advance(4)
                if step <= 15 && step % 5 == 0 { try await crossingChunk(40 + step) }
                if step >= 15 && inHistory(from: start) { break }
            }
            guard inHistory(from: start) else { throw ValidationError("the notches did not reach lazy history") }
            trace.mark("fixture.crossedIntoHistory")
        }
        for _ in 0..<96 {
            try scroll(up: -viewport / 3)
            await trace.advance(4)
            if trace.guardian.following && trace.guardian.distance <= ThreadTailGuard.slack { break }
        }
        guard trace.guardian.following, trace.guardian.distance <= ThreadTailGuard.slack else {
            throw ValidationError("the notched return did not resume following")
        }
        trace.mark("fixture.crossBandBackAtTail")
        await trace.settle()
    }

    private func crossingChunk(_ index: Int) async throws {
        // The hold may mask layout changes; require the streamed row itself to grow.
        try await streamChunk(index, marker: "fixture.crossBandChunk", requireDocumentChange: false)
    }

    private func streamChunk(_ index: Int, marker: String, requireDocumentChange: Bool = true) async throws {
        let oldHeight = trace.latest?.documentHeight
        guard let oldRowHeight = trace.latest?.streamingRowHeight else { throw ValidationError("missing streaming row") }
        trace.mark(marker)
        thread.provisional[0].blocks[0].text += "Inspecting fixture group \(index). The query returns the rows in ascending order.\n\n"
        await publish()
        try await trace.waitFor("stream chunk \(index) to grow the row") {
            (self.trace.latest?.streamingRowHeight ?? 0) > oldRowHeight
                && (!requireDocumentChange || self.trace.latest?.documentHeight != oldHeight)
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
        if ThreadScrollValidation.timingWheel {
            trace.wheelLayoutRunning = true
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            window.layoutIfNeeded()
            let second = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            window.contentView?.layoutSubtreeIfNeeded()
            wheelLayoutTimes = (second - start, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - second)
            trace.wheelLayoutRunning = false
        } else {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }
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

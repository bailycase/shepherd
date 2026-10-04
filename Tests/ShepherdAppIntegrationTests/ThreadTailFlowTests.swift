import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// What `ThreadBlankScreenTests` leaves out: the thread as the app has it. It sits in its own
/// hosting view in the layout deck's container (`AgentLayoutDeck`: an explicit frame, no sizing, no
/// safe area), over a terminal panel that comes and goes with the content animation, a visibility
/// flip hides and shows it (`isHidden` and `active`), its history is the host's window of 50
/// messages with older pages behind a cursor, its rows differ in height as a real thread's do (a
/// long answer runs to thousands of points), and what it draws is read from the window with real
/// time passing between changes.
///
/// A lazy stack that follows its tail over such rows can strand the scroll view past every row it
/// placed: its numbers say the tail, and the viewport draws nothing, for as long as nothing moves
/// it (`ThreadTailGuard`). A blank that lasts is the failure here; the frames in which the guard is
/// still noticing are not. On any machine a sequence must end with the thread drawing and its
/// tail kept, and the guard not putting it back over and over; where wall-clock time counts (not
/// on CI, `TimingTests`), a thread must also never draw nothing for more than `blankLimit`.
@Suite("Thread tail in the app's layout", .serialized, .mainActorExclusive)
@MainActor
struct ThreadTailFlowTests {
    typealias Fx = ThreadBlankScreenTests

    /// A thread that draws nothing for this long (in seconds) is stranded, not catching up. A
    /// wall-clock budget: asserted only under `TimingTests.enabled`.
    static let blankLimit = 0.6

    nonisolated static let short = CGSize(width: 900, height: 600)
    nonisolated static let tall = CGSize(width: 1400, height: 1100)
    nonisolated static let sizes = [short, tall]

    /// How much rows differ: every `every`th turn ends in an answer of `paragraphs` paragraphs
    /// and two code blocks, so a row can be taller than the window by many times.
    enum Mix: Sendable, CustomTestStringConvertible {
        case moderate, giant
        var paragraphs: Int { self == .giant ? 100 : 30 }
        var every: Int { self == .giant ? 5 : 7 }
        var testDescription: String { self == .giant ? "rows of 9,000 pt" : "rows of 3,000 pt" }
    }

    // MARK: Host

    /// A host serving a long conversation the way pi's does: the newest 50 messages and a cursor
    /// to older ones, a page of 50 for each request, and an answer that can take its time.
    @MainActor
    final class FlowHost {
        var all: [NativeThreadMessage]
        var provisional: [NativeThreadMessage] = []
        var running = false
        var subagents: [ChildRun] = []
        var turnChanges: [ChangesTurn]?
        /// The host's queue (nil: a host without one); a send while it runs joins it, as pi's host does.
        var queue: NativeQueue?
        /// The prompts the host has sent pi and pi has not started yet, shown as pending rows (a
        /// host with a queue shows its own, the way pi's does).
        var sent: [NativeThreadMessage] = []
        /// The host can stop pi for Steer now (`interrupt` in `supportedActions`).
        var interrupts = false
        /// The host refuses every send.
        var refuses = false
        /// What pi is asking, in the composer's place.
        var dialogs: [NativeThreadDialog] = []
        var revision: UInt64 = 1
        var delay: Duration = .zero
        var olderRequests = 0
        let window = 50

        init(turns: Int, mix: Mix) { all = ThreadTailFlowTests.history(turns: turns, mix: mix) }

        func snapshot() -> NativeThreadSnapshot {
            let tail = Array(all.suffix(window))
            var value = Fx.snapshot(tail, provisional: provisional, running: running, revision: revision, turnChanges: turnChanges)
            value.olderCursor = tail.count < all.count ? tail.first?.entryID : nil
            value.subagents = subagents
            value.provisional += sent
            value.dialogs = dialogs
            value.queue = queue
            if interrupts { value.supportedActions.append("interrupt") }
            return value
        }

        func answer(_ request: NativeThreadRequest) async -> NativeThreadResult {
            if delay > .zero { try? await Task.sleep(for: delay) }
            switch request {
            case .snapshot(_, let before?, _):
                guard let index = all.firstIndex(where: { $0.entryID == before }) else { return .snapshot(value: snapshot()) }
                olderRequests += 1
                let start = max(0, index - window)
                var page = Fx.snapshot(Array(all[start..<index]), revision: revision)
                page.olderCursor = start > 0 ? all[start].entryID : nil
                return .snapshot(value: page)
            case .send(_, _, let operation, let text, let delivery, _, _, _, _):
                if refuses { return .failure(code: "refused", message: "pi refused the message.") }
                if running, queue != nil {
                    var items = queue?.items ?? []
                    items.append(NativeQueuedMessage(id: operation, text: text, sentAt: Date().timeIntervalSince1970 * 1000,
                                                     state: delivery == .steer ? .steering : .queued))
                    if delivery == .interrupt { NativeQueueRules.interrupt([operation], in: &items) }
                    NativeQueueRules.normalize(&items)
                    queue?.items = items
                    bump()
                } else if queue != nil {
                    sent.append(NativeThreadMessage.pendingSend(operationID: operation, text: text, images: 0, timestamp: Date().timeIntervalSince1970 * 1000))
                    bump()
                }
                return .accepted(operationID: operation)
            default:
                return .snapshot(value: snapshot())
            }
        }

        func bump() { revision += 1 }

        /// pi starts the prompt the host sent it: the host's pending row becomes the message pi read.
        func piStarts(_ id: String, _ text: String, at: Double) {
            var message = Fx.user(id, text, at: at)
            message.operationID = sent.first?.operationID
            sent.removeAll()
            all.append(message)
        }
    }

    static func history(turns: Int, mix: Mix) -> [NativeThreadMessage] {
        (0..<turns).flatMap { n -> [NativeThreadMessage] in
            var out = Fx.turn(n)
            if n % mix.every == 3, let last = out.indices.last {
                out[last] = Fx.reply("a\(n)", Fx.prose(mix.paragraphs, n) + "\n\n" + Fx.code(n) + "\n\n" + Fx.prose(12, n) + "\n\n" + Fx.code(n + 5),
                                     at: Fx.base + Double(n) * 60_000 + 5000)
            }
            return out
        }
    }

    // MARK: Deck

    @MainActor @Observable
    final class DeckModel {
        var active = true
        var panel = false
        var panelHeight: CGFloat = 260
        /// The thread offers the subagent tray (`inspectSubagent` is given), as the app's does.
        var tray = false
    }

    /// The thread in the layout's arrangement: a leaf of fixed size in a ZStack, with the terminal
    /// panel's room taken from its height.
    struct DeckRoot: View {
        let model: DeckModel
        let store: NativeThreadStore
        let request: NativeThreadStore.Request
        let preview: NativeThreadStore.Preview?
        let commands: ThreadCommandCenter
        let tailGuard: ThreadTailGuard
        let native: Bool

        var body: some View {
            let active = model.active
            GeometryReader { geo in
                let panel = model.panel
                let height = panel ? geo.size.height - model.panelHeight : geo.size.height
                ZStack(alignment: .topLeading) {
                    ThreadView(store: store, active: active, isFocused: false, request: request, preview: preview,
                               commandKey: "flow", inspectSubagent: model.tray ? { _ in } : nil, listModels: { .empty }, retainedTailGuard: tailGuard, nativeTail: native)
                        .frame(width: geo.size.width, height: height)
                    Color.nw.bgRaised
                        .frame(width: geo.size.width, height: model.panelHeight)
                        .offset(y: height)
                        .opacity(panel ? 1 : 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .nwAnimation(.content, value: panel)
            }
            .environment(\.nwMotionPaused, !active)
            .environment(\.threadCommands, commands)
        }
    }

    final class Container: NSView {
        weak var page: NSView?
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            if let page, page.frame != bounds { page.frame = bounds }
        }
    }

    final class Page: NSHostingView<DeckRoot> {
        required init(rootView: DeckRoot) {
            super.init(rootView: rootView)
            sizingOptions = []
            safeAreaRegions = []
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    /// What the window showed in one frame.
    struct State: CustomStringConvertible {
        var reading: Fx.Reading?
        /// Pixels in the thread's own area (above the composer) unlike its background.
        var ink: Int
        var description: String { "\(ink) px drawn; \(reading.map(String.init(describing:)) ?? "no scroll view")" }
    }

    @MainActor
    final class Deck {
        let model = DeckModel()
        let commands = ThreadCommandCenter()
        let tailGuard = ThreadTailGuard()
        let store = NativeThreadStore()
        let host: FlowHost
        let window: OffscreenWindow
        let container = Container()
        let page: Page
        var timeline: [(t: Double, state: State)] = []
        private let started = ContinuousClock.now

        init(host: FlowHost, size: CGSize, native: Bool, preview: NativeThreadStore.Preview? = nil) {
            self.host = host
            window = OffscreenWindow(size: size, dark: true)
            let request: NativeThreadStore.Request = { [host] in await host.answer($0) }
            page = Page(rootView: DeckRoot(model: model, store: store, request: request, preview: preview, commands: commands,
                                           tailGuard: tailGuard, native: native))
            container.frame = CGRect(origin: .zero, size: size)
            container.addSubview(page)
            container.page = page
            page.frame = container.bounds
            window.window.contentView = container
            window.window.orderBack(nil)
            layout()
        }

        func close() {
            tailGuard.stop()
            store.stop()
            window.close()
        }

        func layout() {
            window.window.layoutIfNeeded()
            container.layoutSubtreeIfNeeded()
            page.layoutSubtreeIfNeeded()
        }

        var scrollView: NSScrollView? {
            func all(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] + $0.subviews.flatMap(all) } ?? view.subviews.flatMap(all)
            }
            return all(page).max { $0.frame.height < $1.frame.height }
        }

        var reading: Fx.Reading? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let clip = scroll.contentView
            return Fx.Reading(content: document.bounds.height, offset: clip.bounds.origin.y, viewport: clip.bounds.height,
                              insetTop: scroll.contentInsets.top, insetBottom: scroll.contentInsets.bottom)
        }

        /// Draws the thread's own area, above the composer, and counts the pixels unlike its
        /// background.
        func state() -> State {
            guard let scroll = scrollView else { return State(reading: nil, ink: 0) }
            let reading = self.reading
            var region = scroll.convert(scroll.bounds, to: page)
            region.size.height = max(1, region.height - (reading?.insetBottom ?? 0) - 24)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width.rounded(.up)), pixelsHigh: Int(region.height.rounded(.up)),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = region.size
            page.cacheDisplay(in: region, to: bitmap)
            let p = UnsafeBufferPointer(start: bitmap.bitmapData!, count: bitmap.bytesPerPlane)
            let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
            var ink = 0
            for y in 0..<bitmap.pixelsHigh {
                let row = y * bitmap.bytesPerRow
                for x in 0..<bitmap.pixelsWide {
                    let i = row + x * 4
                    if abs(Int(p[i]) - r) > 12 || abs(Int(p[i + 1]) - g) > 12 || abs(Int(p[i + 2]) - b) > 12 { ink += 1 }
                }
            }
            return State(reading: reading, ink: ink)
        }

        var seconds: Double {
            let d = ContinuousClock.now - started
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        /// The longest stretch of frames in which the thread drew nothing, in seconds.
        var longestBlank: Double {
            var longest = 0.0
            var start: Double?
            for entry in timeline {
                if entry.state.ink == 0 { start = start ?? entry.t; longest = max(longest, entry.t - start!) } else { start = nil }
            }
            return longest
        }

        /// How long the thread has drawn nothing up to now (0 when it draws).
        var currentBlank: Double {
            guard let last = timeline.last, last.state.ink == 0 else { return 0 }
            var start = last.t
            for entry in timeline.reversed() { if entry.state.ink == 0 { start = entry.t } else { break } }
            return last.t - start
        }

        /// Lets `duration` of real time pass, laying out and drawing about every 16 ms, and notes
        /// what the window showed (nothing while the thread is hidden).
        func pass(_ duration: Duration = .milliseconds(300)) async throws {
            let end = ContinuousClock.now + duration
            repeat {
                try await Task.sleep(for: .milliseconds(16))
                layout()
                if page.isHidden { continue }
                timeline.append((seconds, state()))
            } while ContinuousClock.now < end
        }

        /// Whether something is drawn and the view is at its tail. The scroll view's numbers can
        /// call a view the tail that is not (they come from the lazy stack's guesses): it is the
        /// tail where SwiftUI says the bottom marker is in view, or where the numbers agree.
        func atTail(_ state: State) -> Bool {
            guard let reading = state.reading else { return false }
            return state.ink > 0 && (tailGuard.visible.contains(ThreadView.bottomID)
                || (reading.distance >= -2 && reading.distance <= NativeScrollFollower.threshold))
        }

        /// Waits for the thread to draw its tail and keep it for `holding`, with time passing.
        func expectTail(_ what: String, within: Duration = .seconds(8), holding: Duration = .milliseconds(250)) async throws {
            var last = state()
            let deadline = ContinuousClock.now + within
            var stableSince: ContinuousClock.Instant?
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(16))
                layout()
                last = state()
                timeline.append((seconds, last))
                if atTail(last) {
                    stableSince = stableSince ?? .now
                    if ContinuousClock.now - stableSince! >= holding { return }
                } else {
                    stableSince = nil
                }
            }
            throw TimedOut(what: "\(what): the thread to draw and keep its tail (\(last); in view: \(tailGuard.visible.suffix(3)) of \(store.rows.count) rows)")
        }

        /// What every sequence ends with. On any machine: the thread ends it drawing, and the guard
        /// did not keep putting it back (`budget` repairs at most, counted by `NWRenderProbe`).
        /// Where wall-clock time counts (`TimingTests`, not CI): it never drew nothing for more
        /// than `blankLimit`.
        func expectSettled(repairs budget: Int) async throws {
            // A frame can fall in a flash of blank the guard is still noticing (anchored, in a short
            // window): the thread has to draw again within a few seconds, not in every frame.
            let deadline = ContinuousClock.now + .seconds(8)
            repeat { try await pass(.milliseconds(50)) } while (timeline.last?.state.ink ?? 0) == 0 && ContinuousClock.now < deadline
            #expect((timeline.last?.state.ink ?? 0) > 0, "the thread ended the sequence drawing nothing")
            #expect(NWRenderProbe.count("thread.tailRepair") <= budget, "the guard put the thread back \(NWRenderProbe.count("thread.tailRepair")) times")
            if TimingTests.enabled {
                #expect(longestBlank < ThreadTailFlowTests.blankLimit, "the thread drew nothing for \(longestBlank) s (\(timeline.count) frames)")
            }
        }

        func publish(running: Bool? = nil, provisional: [NativeThreadMessage]? = nil, _ change: (FlowHost) -> Void = { _ in }) async {
            if let running { host.running = running }
            if let provisional { host.provisional = provisional }
            change(host)
            host.bump()
            await store.refresh()
            layout()
        }

        func open(_ what: String = "opening") async throws {
            try await eventuallyOnMain("the thread to load") { store.ready }
            try await expectTail(what)
        }

        /// The layout deck's flip: `isHidden` and `active` change together.
        func hide() {
            model.active = false
            page.isHidden = true
            layout()
        }

        func show() {
            page.isHidden = false
            model.active = true
            layout()
        }

        func resize(to size: CGSize) {
            window.window.setContentSize(size)
            layout()
        }

        /// ⌥⌘↑/↓, the reader's way to leave the tail and come back without an event.
        func command(_ command: ThreadCommandCenter.Command) {
            commands.send(command, to: "flow")
            layout()
        }

        /// Moves the clip view the way a reader's scroll does (no events).
        func scroll(by delta: CGFloat) {
            guard let scroll = scrollView else { return }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y += delta
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            layout()
        }

        /// A user turn and then a streamed reply with tool calls, to a finished turn with its
        /// "Edited N files" card: the changes a running agent makes at the tail.
        func runTurn(_ k: Int, steps: Int = 6, pause: Duration = .milliseconds(60)) async throws {
            let promptAt = Fx.base + Double(10_000 + k) * 60_000
            await publish(running: true, provisional: []) { $0.all.append(Fx.user("turn\(k)u", "Prompt \(k): run the tests please.", at: promptAt)) }
            for step in 0..<steps {
                await publish(running: true, provisional: [Fx.streamingReply(1 + step / 2)]) {
                    if step % 2 == 1 {
                        $0.all.append(Fx.tool("turn\(k)t\(step)", "bash", ["command": "swift test"],
                                              output: (0..<(2 + step)).map { "line \($0)" }.joined(separator: "\n"), at: promptAt + Double(step) * 1000))
                    }
                }
                try await pass(pause)
            }
            await publish(running: false, provisional: []) {
                $0.turnChanges = [Fx.recorded(promptAt: promptAt)]
                $0.all.append(Fx.reply("turn\(k)a", Fx.prose(3, k) + "\n\n" + Fx.code(k), at: promptAt + 60_000))
            }
        }
    }

    /// Before macOS 27 the thread anchors itself to its tail (`ThreadTailAnchor.isNative`).
    static var beforeMacOS27: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 }

    /// A deck over a long history, open on its tail, for `body`, and then `expectSettled`. It
    /// follows its tail by scrolling alone unless `native` anchors it, and with `guarding` off it is
    /// left as the lazy stack leaves it. `history` replaces the host's generated one, `configure`
    /// sets the host up, `previewing` gives the thread what it previewed from pi's session file, and
    /// `repairs` is how many times the guard may put the thread back over the whole sequence.
    ///
    /// An anchored thread in a short window stays blank for seconds at its opening on the macOS 26
    /// runner (the known issue in `ThreadBlankScreenTests`, 900x600 and 1100x700, the same 8 cases
    /// before and after the guard): the anchored short cases are known issues before macOS 27. So is
    /// following by scrolling there, a mode the thread only uses from macOS 27 and that the slow
    /// runner's stack can leave short of its tail for longer than a test waits. And so are the tall
    /// anchored cases: the runner's stack strands a 9,000 pt-row thread at its opening in them too
    /// (1400x1100 timed out on #190), and the guard exists for macOS 27's stack, so before 27 the whole
    /// sequence is an intermittent known issue.
    static func withDeck(size: CGSize, mix: Mix = .moderate, native: Bool = false, guarding: Bool = true, turns: Int = 120,
                         history: [NativeThreadMessage]? = nil, previewing: Bool = false,
                         repairs: Int = ThreadTailGuard.maxAttempts * 3, configure: (FlowHost) -> Void = { _ in },
                         _ body: (Deck) async throws -> Void) async throws {
        let host = FlowHost(turns: turns, mix: mix)
        if let history { host.all = history }
        configure(host)
        let snapshot = host.snapshot()
        let preview: NativeThreadStore.Preview? = previewing ? { @Sendable in snapshot } : nil
        let deck = Deck(host: host, size: size, native: native, preview: preview)
        deck.tailGuard.enabled = guarding
        NWRenderProbe.start()
        defer {
            NWRenderProbe.stop()
            deck.close()
        }
        try await withKnownIssue("an anchored thread stays blank at its opening in a short window before macOS 27", isIntermittent: true) {
            try await body(deck)
            try await deck.expectSettled(repairs: repairs)
        } when: { beforeMacOS27 }
    }

    // MARK: Opening

    struct OpeningCase: Sendable, CustomTestStringConvertible {
        var size: CGSize
        var mix: Mix
        var native: Bool
        var testDescription: String {
            "\(Int(size.width))x\(Int(size.height)), \(mix.testDescription), \(native ? "anchored" : "following by scrolling")"
        }
    }

    nonisolated static let openings = sizes.flatMap { size in
        [Mix.moderate, .giant].flatMap { mix in [false, true].map { OpeningCase(size: size, mix: mix, native: $0) } }
    }

    /// A long thread opens on its tail, whether or not the scroll view anchors itself there.
    @Test(arguments: openings)
    func aLongThreadOpensOnItsTail(_ c: OpeningCase) async throws {
        try await Self.withDeck(size: c.size, mix: c.mix, native: c.native) { deck in
            try await deck.open()
        }
    }

    /// pi's answer is not there at the first frame: the thread shows what it previewed from the
    /// session file, then the newest 50 messages arrive and it lands on their tail.
    @Test(arguments: sizes)
    func historyArrivingAfterTheThreadMountedLandsOnItsTail(size: CGSize) async throws {
        try await Self.withDeck(size: size, previewing: true, configure: { $0.delay = .milliseconds(400) }) { deck in
            try await deck.open("history after mount")
            try await deck.runTurn(1)
            try await deck.expectTail("a turn after the history arrived")
        }
    }

    // MARK: A terminal panel under a running turn

    struct PanelCase: Sendable, CustomTestStringConvertible {
        var size: CGSize
        var panel: CGFloat
        /// Paragraphs in the turn's final reply.
        var paragraphs = 3
        var native: Bool
        var testDescription: String {
            "\(Int(size.width))x\(Int(size.height)) with a \(Int(panel)) pt panel, a \(paragraphs)-paragraph reply, \(native ? "anchored" : "following by scrolling")"
        }
    }

    nonisolated static let panels = [false, true].flatMap { native in
        [PanelCase(size: short, panel: 260, native: native), PanelCase(size: tall, panel: 140, native: native),
         PanelCase(size: tall, panel: 500, native: native), PanelCase(size: tall, panel: 140, paragraphs: 12, native: native)]
    }

    /// An agent opens a terminal in the middle of a turn: the panel slides in under the thread,
    /// goes again, comes back, and the turn finishes into its footer and its card with the panel
    /// open. In the 900x600 window with the 260 pt panel the thread has 194 pt of room.
    static func aTurnWithATerminalPanelOpeningAndClosing(_ c: PanelCase, guarding: Bool = true) async throws {
        try await withDeck(size: c.size, native: c.native, guarding: guarding) { deck in
            deck.model.panelHeight = c.panel
            try await deck.open()
            let promptAt = Fx.base + 20_000 * 60_000
            await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("panel-u", "Run the tests please.", at: promptAt)) }
            try await deck.expectTail("a turn started")
            for step in 0..<4 {
                await deck.publish(running: true, provisional: [Fx.streamingReply(1 + step)])
                try await deck.pass(.milliseconds(80))
            }
            deck.model.panel = true
            for step in 4..<10 {
                await deck.publish(running: true, provisional: [Fx.streamingReply(1 + step)])
                try await deck.pass(.milliseconds(80))
            }
            try await deck.expectTail("the panel open and the reply streaming")
            deck.model.panel = false
            for step in 10..<14 {
                await deck.publish(running: true, provisional: [Fx.streamingReply(1 + step)])
                try await deck.pass(.milliseconds(80))
            }
            try await deck.expectTail("the panel closed")
            deck.model.panel = true
            try await deck.pass(.milliseconds(500))
            await deck.publish(running: false, provisional: []) {
                $0.turnChanges = [Fx.recorded(promptAt: promptAt)]
                $0.all.append(Fx.reply("panel-a", Fx.prose(c.paragraphs, 40) + "\n\n" + Fx.code(40), at: promptAt + 60_000))
            }
            try await deck.expectTail("the turn finished with the panel open")
        }
    }

    @Test(arguments: panels)
    func aTerminalPanelOpeningAndClosingDuringATurnKeepsTheTail(_ c: PanelCase) async throws {
        try await Self.aTurnWithATerminalPanelOpeningAndClosing(c)
    }

    /// With recovery disabled, finishing a turn with the panel open can leave the lazy stack's
    /// scroll view past its last row. This OS failure is intermittent: the same sequence also
    /// settles correctly on macOS 27. A passing run does not establish that recovery is unnecessary.
    @Test func withoutTheGuardTheLazyStackStrandsTheThreadBlank() async throws {
        guard !Self.beforeMacOS27 else { return }
        await withKnownIssue("a lazy stack's guesses leave the scroll view past its rows, drawing nothing", isIntermittent: true) {
            try await Self.aTurnWithATerminalPanelOpeningAndClosing(PanelCase(size: Self.short, panel: 260, native: false), guarding: false)
        }
    }

    /// A thread that is not stranded is not walked: on macOS 27's stack, the guard stays out of the
    /// way of a turn that streams, with its tool calls and its card, in rows of the plain mix. The
    /// macOS 26 runner strands this thread once in the tall window (one repair, and nearly a second
    /// of blank on its slow machine) and the guard puts it back: there the turn only has to end
    /// with the thread drawing its tail.
    @Test(arguments: sizes)
    func aTurnStreamingOnAThreadThatIsNotStrandedIsNotWalked(size: CGSize) async throws {
        try await Self.withDeck(size: size, history: Fx.history(turns: 40)) { deck in
            try await deck.open()
            NWRenderProbe.start()
            try await deck.runTurn(1)
            try await deck.expectTail("the turn finished")
            if !Self.beforeMacOS27 {
                #expect(NWRenderProbe.count("thread.tailRepair") == 0, "the guard walked a thread that was not stranded")
            }
        }
    }

    // MARK: A reader

    /// A reader leaving the tail by turns (⌥⌘↑), through the loaded history and the pages of older
    /// history that load as they reach the top, and on down it: every place draws. A send then
    /// takes them back to the tail.
    @Test(.timingSensitive) func readingUpThroughPagedHistoryAndBackDrawsEveryPlace() async throws {
        try await Self.withDeck(size: Self.tall, turns: 200, repairs: ThreadTailGuard.maxAttempts * 6) { deck in
            try await deck.open()
            for step in 0..<80 {
                if step < 50 { deck.command(.previousTurn) } else { deck.scroll(by: -Self.tall.height * 0.8) }
                try await deck.pass(.milliseconds(100))
                if (deck.reading?.offset ?? 1) <= -(deck.reading?.insetTop ?? 0) + 1, deck.host.olderRequests >= 2 { break }
            }
            #expect(deck.host.olderRequests >= 1, "the reader reached the top of the loaded history, and a page of older history loaded")
            for _ in 0..<30 {
                deck.scroll(by: Self.tall.height * 0.8)
                try await deck.pass(.milliseconds(32))
            }
            deck.store.draft = "Thanks, continue."
            await deck.store.send()
            await deck.publish(running: true, provisional: []) {
                $0.all.append(Fx.user("answer", "Thanks, continue.", at: Fx.base + 20_000 * 60_000))
            }
            try await deck.expectTail("back at the tail after sending")
        }
    }

    // MARK: The layout around the thread

    /// A thread streaming a turn while hidden, shown again after it finished.
    @Test(arguments: sizes)
    func aThreadThatRanWhileHiddenDrawsItsTailWhenShownAgain(size: CGSize) async throws {
        try await Self.withDeck(size: size) { deck in
            try await deck.open()
            let promptAt = Fx.base + 20_000 * 60_000
            await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("hidden-u", "Run the tests.", at: promptAt)) }
            try await deck.expectTail("a turn started")
            deck.hide()
            try await deck.pass(.milliseconds(200))
            for k in 0..<6 {
                await deck.publish(running: true, provisional: [Fx.streamingReply(1 + k)]) {
                    $0.all.append(Fx.tool("hidden-t\(k)", "bash", ["command": "swift test"],
                                          output: (0..<(3 + k)).map { "line \($0)" }.joined(separator: "\n"), at: promptAt + Double(k) * 1000))
                }
                try await deck.pass(.milliseconds(60))
            }
            await deck.publish(running: false, provisional: []) {
                $0.turnChanges = [Fx.recorded(promptAt: promptAt)]
                $0.all.append(Fx.reply("hidden-a", Fx.prose(3, 1) + "\n\n" + Fx.code(1), at: promptAt + 60_000))
            }
            try await deck.pass(.milliseconds(300))
            deck.show()
            try await deck.expectTail("shown again after the turn")
        }
    }

    /// The thread flipped away and back four times while its turn runs.
    @Test(.timingSensitive) func aThreadFlippedHiddenAndShownDuringATurnKeepsItsTail() async throws {
        try await Self.withDeck(size: Self.short) { deck in
            try await deck.open()
            let promptAt = Fx.base + 20_000 * 60_000
            await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("flip-u", "Run the tests please.", at: promptAt)) }
            try await deck.expectTail("a turn started")
            for round in 0..<4 {
                deck.hide()
                try await deck.pass(.milliseconds(150))
                // pi keeps working while the agent is hidden: the thread has no loop to see it.
                deck.host.provisional = [Fx.streamingReply(1 + round * 3)]
                if round % 2 == 1 {
                    deck.host.all.append(Fx.tool("flip-t\(round)", "bash", ["command": "swift test"], output: "ok\nok\nok", at: promptAt + Double(round) * 1000))
                }
                deck.host.bump()
                deck.show()
                try await deck.expectTail("shown again, round \(round)")
                await deck.publish(running: true, provisional: [Fx.streamingReply(2 + round)])
                try await deck.expectTail("streaming after round \(round)")
            }
        }
    }

    /// A long live turn settles into the host's 50-message history window. Its prompt falls out
    /// of that window, so the reply changes identity and height while the completed workers stay
    /// above the composer.
    @Test(arguments: sizes)
    func aLongTurnSettlingIntoPagedHistoryWithFinishedWorkersKeepsTheTranscript(size: CGSize) async throws {
        try await Self.withDeck(size: size) { deck in
            deck.model.tray = true
            try await deck.open()
            let at = Fx.base + 40_000 * 60_000
            var live = [Fx.user("long-u", "Review the changes with two workers.", at: at)]
            let workers = (0..<2).map { i in
                ChildRun(runID: "worker-\(i)", label: "Review changes", state: "running", startedAt: at + Double(i), role: "worker")
            }
            for step in 0..<4 {
                for n in (step * 15)..<((step + 1) * 15) {
                    live.append(Fx.reply("long-a\(n)", Fx.prose(3, n), at: at + Double(n) * 1000))
                    live.append(Fx.tool("long-t\(n)", "read", ["path": "Sources/File\(n).swift"], output: "File contents", at: at + Double(n) * 1000))
                }
                await deck.publish(running: true, provisional: live) { $0.subagents = workers }
                try await deck.expectTail("long turn streaming \(step)")
            }
            live.append(Fx.reply("long-final", "The review is complete. Both workers finished.", at: at + 70_000))
            await deck.publish(running: false, provisional: []) {
                $0.all += live
                $0.subagents = workers.map { run in
                    var done = run
                    done.state = "complete"
                    done.endedAt = at + 69_000
                    done.summary = "Review complete."
                    return done
                }
            }
            try await eventuallyOnMain("the turn to settle") { !deck.store.running }
            #expect(deck.store.rows.count == 1, "the history window no longer contains the prompt")
            #expect(deck.store.tray != nil)
            try await deck.expectTail("the long turn and workers finished")
        }
    }

    /// A finished subagent's tray over the composer, then gone.
    @Test(.timingSensitive, arguments: sizes)
    func aFinishedSubagentTrayCollapsingKeepsTheTail(size: CGSize) async throws {
        try await Self.withDeck(size: size) { deck in
            deck.model.tray = true
            try await deck.open()
            try await deck.runTurn(1)
            var run = ListFixtures.run(0, state: "complete")
            run.startedAt = try #require(deck.store.lastPromptAt)
            await deck.publish { $0.subagents = [run] }
            #expect(deck.store.tray != nil)
            try await deck.expectTail("a turn with the tray")
            await deck.publish { $0.subagents = [] }
            #expect(deck.store.tray == nil)
            try await deck.expectTail("the tray gone")
        }
    }

    /// The window resized, in height and in width, while the thread follows its tail.
    @Test(.timingSensitive) func resizingTheWindowKeepsTheTail() async throws {
        try await Self.withDeck(size: Self.tall) { deck in
            try await deck.open()
            for height in [900.0, 700.0, 500.0, 800.0, 1100.0] {
                deck.resize(to: CGSize(width: 1400, height: height))
                try await deck.expectTail("resized to \(height) tall")
            }
            for width in [1000.0, 700.0, 1400.0] {
                deck.resize(to: CGSize(width: width, height: 900))
                try await deck.expectTail("resized to \(width) wide")
            }
        }
    }

    // MARK: A session

    struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    enum Action: CaseIterable {
        case prompt, stream, streamMore, tool, toolMore, finish, panel, tray, flip, resize, readEarlier, answer
    }

    struct SessionCase: Sendable, CustomTestStringConvertible {
        var size: CGSize
        var seed: UInt64
        var mix: Mix
        var testDescription: String { "\(Int(size.width))x\(Int(size.height)), \(mix.testDescription), seed \(seed)" }
    }

    nonisolated static let sessions = [SessionCase(size: short, seed: 1, mix: .moderate), SessionCase(size: short, seed: 2, mix: .giant),
                           SessionCase(size: tall, seed: 1, mix: .moderate), SessionCase(size: tall, seed: 2, mix: .giant)]

    /// Thirty-two steps of an agent and a reader, drawn from a seed: turns starting, streaming,
    /// calling tools and finishing; the terminal panel, the subagent tray, the window and the
    /// visibility flip changing the room; the reader going back by turns and answering. Following
    /// the tail, it is on it after each step; reading earlier output, something is drawn.
    @Test(.timingSensitive, arguments: sessions)
    func aRandomSessionOfTurnsPanelsFlipsAndReadingNeverLeavesTheThreadBlank(_ c: SessionCase) async throws {
        try await Self.withDeck(size: c.size, mix: c.mix, repairs: ThreadTailGuard.maxAttempts * 8) { deck in
            try await deck.open()
            var rng = Lcg(state: c.seed)
            var turnOpen = false
            var reading = false
            var counter = 0
            let runs = [ListFixtures.run(0, state: "complete")]

            @MainActor func promptAt() -> Double { Fx.base + Double(30_000 + counter) * 60_000 }
            @MainActor func openTurn() async {
                guard !turnOpen else { return }
                counter += 1
                turnOpen = true
                await deck.publish(running: true, provisional: []) {
                    $0.all.append(Fx.user("fz\(counter)u", "Prompt \(counter): please run the tests and fix what fails.", at: promptAt()))
                }
            }
            @MainActor func finishTurn() async {
                guard turnOpen else { return }
                turnOpen = false
                let at = promptAt()
                await deck.publish(running: false, provisional: []) {
                    $0.turnChanges = [Fx.recorded(promptAt: at)]
                    $0.all.append(Fx.reply("fz\(counter)a", Fx.prose(1 + counter % 4, counter) + "\n\n" + Fx.code(counter), at: at + 60_000))
                }
            }

            for step in 0..<32 {
                let action = Action.allCases[rng.next(Action.allCases.count)]
                switch action {
                case .prompt:
                    await finishTurn()
                    await openTurn()
                case .stream, .streamMore:
                    await openTurn()
                    await deck.publish(running: true, provisional: [Fx.streamingReply(1 + rng.next(6))])
                case .tool, .toolMore:
                    await openTurn()
                    counter += 1
                    let id = counter
                    await deck.publish(running: true) {
                        $0.all.append(Fx.tool("fz\(id)t", "bash", ["command": "swift test --filter T\(id)"],
                                              output: (0..<(2 + rng.next(30))).map { "output line \($0)" }.joined(separator: "\n"),
                                              at: Fx.base + Double(30_000 + id) * 60_000))
                    }
                case .finish:
                    await finishTurn()
                case .panel:
                    deck.model.panel.toggle()
                case .tray:
                    deck.host.subagents = deck.host.subagents.isEmpty ? runs : []
                    await deck.publish()
                case .flip:
                    deck.hide()
                    try await deck.pass(.milliseconds(120))
                    if turnOpen {
                        deck.host.provisional = [Fx.streamingReply(1 + rng.next(6))]
                    } else {
                        counter += 1
                        deck.host.all.append(Fx.user("fz\(counter)h", "Hidden prompt \(counter)", at: promptAt()))
                        deck.host.running = true
                        turnOpen = true
                    }
                    deck.host.bump()
                    deck.show()
                case .resize:
                    deck.resize(to: [CGSize(width: 900, height: 600), CGSize(width: 1400, height: 1100), CGSize(width: 1100, height: 760),
                                     CGSize(width: 1400, height: 900)][rng.next(4)])
                case .readEarlier:
                    for _ in 0..<(1 + rng.next(3)) {
                        deck.command(.previousTurn)
                        try await deck.pass(.milliseconds(60))
                    }
                    if rng.next(2) == 0 { deck.scroll(by: -CGFloat(100 + rng.next(2500))) }
                    reading = true
                case .answer:
                    // The reader answers: a send that goes in now re-attaches to the tail.
                    await finishTurn()
                    deck.store.draft = "Continue please."
                    await deck.store.send()
                    await openTurn()
                    reading = false
                }
                if reading {
                    try await deck.pass(.milliseconds(250))
                    if TimingTests.enabled {
                        #expect(deck.currentBlank < Self.blankLimit, "blank for \(deck.currentBlank) s while reading earlier output, after \(action) at step \(step)")
                    }
                } else {
                    try await deck.expectTail("step \(step): \(action)")
                }
            }
        }
    }
}

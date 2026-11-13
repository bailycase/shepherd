import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote
@testable import ShepherdUI

/// Hidden threads' row views are bounded across the mounted layouts of a real workspace: past the budget the
/// threads shown longest ago let their rows go, but their last screen, while their hosts, pages, history and drafts stay,
/// and showing one again draws that last screen in the update that shows it, builds nothing then, and brings the rows
/// above it back after that frame, bottom first.
@Suite("Mounted budget", .mainActorExclusive(timeLimit: .seconds(6 * 60)))
@MainActor
struct MountedBudgetTests {
    private static let base = 1_733_000_000_000.0

    /// pi's own message JSON: `replies` question and answer pairs, each answer `cycles` cycles of a paragraph, a Swift
    /// fence, a table and a list, so a thread that keeps its rows shows up as native code fields. The last `shortTail` answers
    /// are one line: a thread whose last screen is shorter than its window.
    private static func seed(replies: Int, cycles: Int, shortTail: Int = 0) -> Data {
        let out: [[String: Any]] = (0..<replies).flatMap { i -> [[String: Any]] in
            let text = i >= replies - shortTail ? "Done." : MarkdownFixtures.longReply(cycles: cycles, from: i * cycles)
            return [["role": "user", "content": "Question \(i)", "timestamp": base + Double(i) * 10_000],
                    ["role": "assistant", "stopReason": "stop", "timestamp": base + Double(i) * 10_000 + 5000,
                     "content": [["type": "text", "text": text]]]]
        }
        return try! JSONSerialization.data(withJSONObject: out)
    }

    /// The native code fields under `view`: what a thread's fences hold while their rows are built.
    private static func nativeFields(in view: NSView) -> Int {
        (view is SHNativeCodeText.Field ? 1 : 0) + view.subviews.reduce(0) { $0 + nativeFields(in: $1) }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    /// What the thread drawn in `scroll` shows above its composer, from one capture of the window.
    private static func drawing(_ window: OffscreenWindow, in scroll: NSScrollView) -> (ink: Int, longestBlankBand: Int) {
        var region = scroll.convert(scroll.bounds, to: window.host)
        region.size.height = max(1, region.height - scroll.contentInsets.bottom - 24)
        let capture = FrameTimer.capture(window, region)
        return (capture.ink, capture.longestBlankBand)
    }

    /// A workspace of agents on stub pis that each hold the same long history, the first on screen and drawn.
    @MainActor
    struct Workspace {
        let vm: ShepherdViewModel
        let window: OffscreenWindow
        let agents: [AgentFixture]

        var stores: NativeThreadStores<AgentID> { vm.threadStores }

        static func open(_ count: Int, replies: Int, cycles: Int, shortTail: Int = 0, in app: AppHarness) async throws -> Workspace {
            let files = try (0..<count).map { index -> URL in
                let file = app.dir.appendingPathComponent("history-\(index).json")
                try MountedBudgetTests.seed(replies: replies, cycles: cycles, shortTail: shortTail).write(to: file)
                return file
            }
            // As the root view hangs the workspace: readers left scrolled up pin their thread's history.
            let (vm, agents) = try await MountedWorkspace.start(count, in: app, env: { ["STUB_PI_MESSAGES_FILE": files[$0].path] })
            let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true,
                                         WorkspaceView(vm: vm).environment(\.threadReaderPins, vm.threadReaderPins))
            let visible = vm.threadStores.store(for: agents[0].agent.id)
            try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
            try await eventuallyOnMain("every layout to mount") { ListPerf.settle(window); return vm.mountedTabs.count == agents.count }
            let workspace = Workspace(vm: vm, window: window, agents: agents)
            try await workspace.settled(0)
            return workspace
        }

        func store(_ index: Int) -> NativeThreadStore { vm.threadStores.store(for: agents[index].agent.id) }

        func deck() throws -> AgentLayoutDeck.Container { try WorkspaceNavigationTests.deck(in: window) }

        func host(_ index: Int) throws -> AgentLayoutDeck.Host? { try deck().pages[agents[index].tab.id]?.host }

        /// The native code fields in agent `index`'s layout, hidden or not.
        func fields(_ index: Int) throws -> Int { try host(index).map { MountedBudgetTests.nativeFields(in: $0) } ?? 0 }

        /// Agent `index`'s transcript: the tallest scroll view of its layout.
        func transcript(_ index: Int) throws -> NSScrollView? {
            try host(index).flatMap { MountedBudgetTests.scrollViews(in: $0).max { $0.frame.height < $1.frame.height } }
        }

        /// How far agent `index`'s view rests above the end of its thread.
        func distanceFromTail(_ index: Int) throws -> CGFloat? {
            guard let scroll = try transcript(index), let document = scroll.documentView else { return nil }
            let clip = scroll.contentView
            return document.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scroll.contentInsets.bottom)
        }

        /// Draws until agent `index`'s thread is loaded, its replies are parsed and its fences stop changing.
        func settled(_ index: Int) async throws {
            let store = self.store(index)
            var last = -1, still = 0
            try await eventuallyOnMain("agent \(index)'s thread to load and draw its fences", timeout: .seconds(90)) {
                ListPerf.settle(window)
                guard store.ready, !store.transcriptReleased else { return false }
                let now = try fields(index)
                still = now > 0 && now == last ? still + 1 : 0
                last = now
                return still >= 5
            }
        }

        /// Shows agent `index` the way the sidebar does, and waits for its thread to draw.
        func show(_ index: Int) async throws {
            try await MountedWorkspace.show(agents[index], in: vm, window: window)
            try await settled(index)
        }

        /// Leaves the thread on screen scrolled up into its history, as a reader does (the wheel monitor's word that a
        /// reader moved it before each tick, then the clip view's movement), and waits for it to stay put.
        func scrollUp(_ index: Int) async throws {
            let scroll = try #require(try transcript(index))
            let clip = scroll.contentView
            let input = vm.threadStores.input(for: agents[index].agent.id)
            for _ in 0..<8 {
                input.readerScrolled(upward: true)
                let target = NSRect(origin: NSPoint(x: 0, y: clip.bounds.origin.y - 250), size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(target).origin)
                scroll.reflectScrolledClipView(clip)
                ListPerf.settle(window)
            }
            var last = clip.bounds.origin.y, still = 0
            try await eventuallyOnMain("the scrolled thread to come to rest", timeout: .seconds(30), poll: .milliseconds(30)) {
                ListPerf.settle(window)
                still = clip.bounds.origin.y == last ? still + 1 : 0
                last = clip.bounds.origin.y
                return still >= 12
            }
        }

        /// Takes the rows of every hidden thread but the ones kept, all of them and in one call.
        @discardableResult
        func releaseHidden(keep: Int = 0, keepPinned: Int = 0) -> (threads: Int, bytes: Int) {
            stores.enforceMountedBudget(budget: 0, keep: keep, keepPinned: keepPinned, limit: .max, step: .max)
        }
    }

    // MARK: The budget

    /// Eight threads of five long replies, a budget for three threads' rows, three last screens and half a thread: once every one has been
    /// shown and the first is on screen again, the hidden threads shown longest ago have let their rows go, a few rows a
    /// pass, and no further than the budget: three down to their last screen and part of the fourth, the three shown last keep
    /// theirs, and the layouts of the released ones hold no more code fields than that.
    @Test func hiddenThreadsKeepNoMoreRowsThanTheBudget() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(8, replies: 5, cycles: 20, in: app)
        defer { work.window.close() }
        let stores = work.stores
        stores.releaseDelay = .zero
        stores.releaseSpacing = .zero
        let one = work.store(0).mountedCost(eagerRows: stores.eagerRows)
        let perThread = try work.fields(0)
        let floor = work.store(0).mountedCost(eagerRows: work.store(0).keptRows)
        #expect(one > 0 && perThread > 0 && floor > 0 && floor < one / 2, "a thread holds rows that cost something: \(one) bytes, \(perThread) fields, \(floor) in its last screen")
        stores.releaseStep = one / 4
        // The three shown last keep all they have, the three oldest go down to their last screens, and the fourth stops halfway between.
        stores.mountedBudget = one * 3 + floor * 3 + (one + floor) / 2

        for index in 1..<8 { try await work.show(index) }
        try await work.show(0)

        let whole = 1...3, last = 4, kept = 5...7
        func atLastScreen(_ index: Int) -> Bool { work.store(index).transcriptDrawn == work.store(index).keptRows }
        func hidden() -> Int { (1..<8).reduce(0) { $0 + work.store($1).mountedCost(eagerRows: stores.eagerRows) } }
        try await eventuallyOnMain("the oldest hidden threads to let their rows go, down to the budget, and the others to keep theirs", timeout: .seconds(60)) {
            ListPerf.settle(work.window)
            return whole.allSatisfy(atLastScreen) && work.store(last).transcriptReleased
                && kept.allSatisfy { !work.store($0).transcriptReleased } && hidden() <= stores.mountedBudget
        }
        try await eventuallyOnMain("a released layout to hold no more than its last screen's code fields", timeout: .seconds(60)) {
            ListPerf.settle(work.window)
            return try whole.allSatisfy { try work.fields($0) < perThread / 2 }
        }
        for index in whole { #expect(try work.fields(index) > 0, "agent \(index) keeps the code fields of its last screen") }
        #expect(!atLastScreen(last), "the fourth stopped when the budget was reached, with rows left")
        for index in kept { #expect(try work.fields(index) > 0, "agent \(index) keeps its fences") }
        let total = try (0..<8).reduce(0) { $0 + (try work.fields($1)) }
        #expect(total <= (1 + kept.count) * perThread * 5 / 4 + perThread, "\(total) fields in the window, a thread holds \(perThread)")
        #expect(!work.store(0).transcriptReleased, "the thread on screen is never released")
        #expect(hidden() <= stores.mountedBudget, "what the hidden threads keep is within the budget: \(hidden()) of \(stores.mountedBudget)")
    }

    // MARK: Switching stays a flip

    @Test func aReleasedThreadKeepsItsHostAndHistory() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        // Thirty-six rows: the last thirty are laid out for real, the ones above them are a lazy stack's.
        let work = try await Workspace.open(3, replies: 18, cycles: 2, in: app)
        defer { work.window.close() }
        for index in [1, 2, 0] { try await work.show(index) }
        let deck = try work.deck()
        let tabs = work.agents.map(\.tab.id)
        let hosts = tabs.map { deck.pages[$0]?.host }, pages = tabs.map { deck.pages[$0]?.page }
        let store = work.store(1)
        store.draft = "a half-written reply"
        let rows = store.rows, messages = store.messages, fences = try work.fields(1)
        #expect(fences > 0 && !rows.isEmpty)
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }

        let taken = work.releaseHidden()
        #expect(taken.threads == 2 && store.transcriptReleased)
        try await eventuallyOnMain("agent 1's layout to hold fewer code fields") {
            ListPerf.settle(work.window)
            return try work.fields(1) < fences
        }
        #expect(store.holdsHistory && store.rows == rows && store.messages == messages && store.draft == "a half-written reply")
        for (index, tab) in tabs.enumerated() {
            #expect(deck.pages[tab]?.host === hosts[index] && deck.pages[tab]?.page === pages[index], "agent \(index)'s host and page are the same objects")
        }

        let parses = store.offMainParses
        try await work.show(1)
        #expect(!store.transcriptReleased && store.offMainParses == parses, "its rows come from what the store kept: nothing is parsed again")
        let again = try work.fields(1)
        #expect(again >= fences * 9 / 10, "the fences of its eager tail are drawn again: \(again) of \(fences)")
        #expect(store.rows == rows && store.messages == messages)
        for (index, tab) in tabs.enumerated() {
            #expect(deck.pages[tab]?.host === hosts[index] && deck.pages[tab]?.page === pages[index], "still the same objects for agent \(index)")
        }
        #expect(SHRenderProbe.count("deck.unmount") == 0 && SHRenderProbe.count("deck.mount") == 0, "no layout was removed or mounted")
    }

    /// Shown again halfway through its release, a thread draws the rows it still had at once and every row it had after that, from what the store kept.
    @Test func aThreadLeftHalfwayReleasedDrawsEverythingWhenShown() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 4, cycles: 15, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        let step = store.mountedCost(eagerRows: work.stores.eagerRows) / 4
        #expect(fences > 0 && step > 0)

        for _ in 0..<2 { #expect(work.stores.enforceMountedBudget(budget: 0, keep: 0, step: step).threads == 1) }
        try await eventuallyOnMain("agent 1's layout to hold fewer code fields, and some") {
            ListPerf.settle(work.window)
            let now = try work.fields(1)
            return now > 0 && now < fences
        }
        #expect(store.transcriptReleased && store.transcriptDrawn != 0)

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        work.vm.selectAgent(work.agents[1].agent.id)
        var passes = 0
        while try work.host(1)?.isHidden != false, passes < 50 {
            ListPerf.settle(work.window)
            passes += 1
        }
        #expect(SHRenderProbe.count("deck.flipLayout") == 1, "a thread that let some rows go is laid out as it is shown too")
        let first = try work.fields(1)
        #expect(first > 0 && first < fences, "the first frame draws the rows it still had: \(first) of \(fences)")
        try await eventuallyOnMain("every fence to be drawn again") { ListPerf.settle(work.window); return try work.fields(1) == fences }
        try await eventuallyOnMain("the thread to run again") { ListPerf.settle(work.window); return !store.transcriptReleased }
        #expect(SHRenderProbe.count("deck.mount") == 0 && SHRenderProbe.count("deck.unmount") == 0)
    }

    /// A release changes what the thread's rows draw and nothing else: the scroll view stays, no entrance plays when the
    /// thread is shown, and the composer is not drawn again but for the one update that carries the release.
    @Test func aReleaseTouchesNothingButItsRows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 3, cycles: 10, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let scroll = try #require(try work.transcript(1))
        let store = work.store(1)
        let structure = store.rowStructureRevision

        let release = ListPerf.counting {
            work.releaseHidden()
            ListPerf.settle(work.window)
        }
        #expect(store.transcriptReleased)
        #expect(release["composer.body", default: 0] <= 1, "\(release)")
        #expect(release["thread.view", default: 0] <= 1, "\(release)")
        #expect(release["thread.agentTurn", default: 0] == 0 && release["thread.userTurn", default: 0] == 0 && release["code.nativeCreated", default: 0] == 0,
                "no turn is drawn again and nothing is built: \(release)")
        #expect(release["arrival.animates", default: 0] == 0, "\(release)")

        SHRenderProbe.start()
        let shown: [String: Int]
        do {
            try await work.show(1)
            shown = SHRenderProbe.stop()
        } catch {
            SHRenderProbe.stop()
            throw error
        }
        #expect(shown["arrival.animates", default: 0] == 0, "no row enters when the thread comes back: \(shown)")
        #expect(try work.transcript(1) === scroll, "the thread's scroll view is the same object")
        #expect(store.rowStructureRevision == structure, "the rows were never rebuilt in the store")
    }

    // MARK: Never blank

    /// Laying the host out in the flip is for a thread that let its rows go, which builds them there: a thread that kept
    /// its rows takes the pass it always did.
    @Test func aFlipLaysTheHostOutOnlyForAThreadThatLetItsRowsGo() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(3, replies: 4, cycles: 8, in: app)
        defer { work.window.close() }
        for index in [1, 2, 0] { try await work.show(index) }
        // The newest hidden thread (2) is never taken: only the older one (1) is.
        #expect(work.stores.enforceMountedBudget(budget: 0, keep: 1, keepPinned: 0, limit: .max, step: .max).threads == 1)
        #expect(work.store(1).transcriptReleased && !work.store(2).transcriptReleased)

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        try await work.show(2)
        #expect(SHRenderProbe.count("deck.flipLayout") == 0, "a thread that kept its rows is shown by the pass that always showed it")
        try await work.show(1)
        #expect(SHRenderProbe.count("deck.flipLayout") == 1, "the thread that let them go is laid out as it is shown")
        #expect(SHRenderProbe.count("deck.mount") == 0 && SHRenderProbe.count("deck.unmount") == 0)
    }

    // MARK: Readers

    @Test func anOlderReaderPastTheBudgetComesBackAtItsTail() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(4, replies: 5, cycles: 15, in: app)
        defer { work.window.close() }
        let pins = work.vm.threadReaderPins
        for index in 1...3 {
            try await work.show(index)
            try await work.scrollUp(index)
            let away = try #require(try work.distanceFromTail(index))
            #expect(away > 80, "agent \(index) is left scrolled up, \(away) points above its tail")
        }
        try await work.show(0)
        try await eventuallyOnMain("the three readers to be pinned") { (1...3).allSatisfy { pins.isPinned(work.store($0)) } }
        let places = try (2...3).map { try #require(try work.transcript($0)).contentView.bounds.origin.y }
        let fences = try (2...3).map { try work.fields($0) }

        // A budget nothing fits: the newest hidden thread (3) and the two most recent readers (2, 3) stay; 1 is the third.
        let before = try work.fields(1)
        let taken = work.releaseHidden(keep: 1, keepPinned: 2)
        #expect(taken.threads == 1)
        try await eventuallyOnMain("the oldest reader's rows to go and its place to be given up") {
            ListPerf.settle(work.window)
            let gone = try work.fields(1) < before
            return work.store(1).transcriptReleased && !pins.isPinned(work.store(1)) && gone
        }
        for (offset, index) in (2...3).enumerated() {
            #expect(!work.store(index).transcriptReleased && pins.isPinned(work.store(index)), "agent \(index) keeps its rows and its place")
            #expect(try work.transcript(index)?.contentView.bounds.origin.y == places[offset], "agent \(index) is where the reader left it")
            #expect(try work.fields(index) == fences[offset])
        }

        try await work.show(1)
        try await eventuallyOnMain("agent 1 to rest at its tail") {
            ListPerf.settle(work.window)
            return try (work.distanceFromTail(1) ?? .infinity) < 8
        }
        #expect(!work.store(1).transcriptReleased && pins.isPinned(work.store(1)), "agent 1 is on screen again, and follows its tail")
    }

    // MARK: The thread view alone

    /// The thread on screen never reads the flag, so a release does not draw it again; hidden, the rows go with it, and
    /// shown again they are back, the thread as tall as before.
    @Test func aThreadOnScreenIgnoresTheFlagAndAHiddenOneDrawsNoRows() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(60)))
        defer { thread.close() }
        try await thread.waitUntilReady()
        func height() throws -> CGFloat { try #require(thread.scrollView?.documentView).bounds.height }
        let tall = try height()
        let rows = thread.store.rows

        let onScreen = ListPerf.counting {
            thread.store.releaseTranscript()
            ListPerf.settle(thread.window)
        }
        #expect(onScreen["thread.view", default: 0] == 0 && onScreen["thread.rowBuilder", default: 0] == 0, "\(onScreen)")
        let same = try height()
        #expect(abs(same - tall) < 2)

        try await thread.show(false)
        ListPerf.settle(thread.window)
        let hidden = try height()
        #expect(hidden < tall / 4, "a hidden thread whose rows went is \(hidden) points tall of \(tall)")
        #expect(thread.store.rows == rows && thread.store.transcriptReleased)

        try await thread.show(true)
        #expect(!thread.store.transcriptReleased)
        try await eventuallyOnMain("the thread to be as tall as before") {
            ListPerf.settle(thread.window)
            return try abs(height() - tall) < tall / 10
        }
    }

    // MARK: The remote deck

    /// A paired Mac's threads, and this Mac's own while the app is the background service's client, are pages of the
    /// remote deck: their hidden pages hold rows too, and go under the same rule.
    @Test func aRemoteDecksHiddenThreadsLetTheirRowsGoToo() async throws {
        let rig = try await RemoteDeckTests.Rig(agents: 3)
        defer { rig.close() }
        for index in 0..<3 { _ = try await rig.firstVisit(index) }
        func fields(_ index: Int) throws -> Int { try rig.host(index).map { Self.nativeFields(in: $0) } ?? 0 }
        let deck = try rig.deck()
        let hosts = try (0..<3).map { try rig.host($0) }
        let fences = try fields(0), second = try fields(1)
        #expect(fences > 0 && second > 0)
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }

        let stores = rig.vm.remoteThreadStores
        #expect(stores.enforceMountedBudget(budget: 0, keep: 0, keepPinned: 0, limit: .max, step: .max).threads == 2, "the two hidden pages")
        try await eventuallyOnMain("the hidden pages to hold fewer code fields") {
            ListPerf.settle(rig.window)
            return try fields(0) < fences && fields(1) < second
        }
        #expect(try fields(2) > 0, "the page on screen keeps its rows")
        for index in 0..<3 { #expect(try deck.pages[rig.refs[index]]?.host === hosts[index], "page \(index) is the same host") }

        _ = try await rig.show(0)
        #expect(SHRenderProbe.count("remoteDeck.flipLayout") == 1, "the page that let its rows go is laid out as it is shown")
        try await eventuallyOnMain("page 0 to draw its fences again") {
            ListPerf.settle(rig.window)
            return try fields(0) >= fences / 2
        }
        let again = try fields(0)
        #expect(again >= fences / 2, "page 0 draws its fences again: \(again) of \(fences)")
        #expect(!rig.store(0).transcriptReleased)
        #expect(SHRenderProbe.count("remoteDeck.unmount") == 0 && SHRenderProbe.count("remoteDeck.mount") == 0)
    }
}

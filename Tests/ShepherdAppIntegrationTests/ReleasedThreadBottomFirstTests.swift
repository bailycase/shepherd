import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote
@testable import ShepherdUI

/// A hidden thread that let its rows go keeps its last screen built, so showing it again builds nothing before the first frame
/// and brings the rest back above that screen over the frames that follow, never moving the end of the thread.
@Suite("Released thread comes back bottom first", .mainActorExclusive(timeLimit: .seconds(6 * 60)))
@MainActor
struct ReleasedThreadBottomFirstTests {
    typealias Workspace = MountedBudgetTests.Workspace

    /// What the thread drawn in `scroll` shows above its composer, from one capture of the window.
    private static func drawing(_ window: OffscreenWindow, in scroll: NSScrollView) -> (ink: Int, longestBlankBand: Int, inkBottom: Int) {
        var region = scroll.convert(scroll.bounds, to: window.host)
        region.size.height = max(1, region.height - scroll.contentInsets.bottom - 24)
        let capture = FrameTimer.capture(window, region)
        return (capture.ink, capture.longestBlankBand, capture.inkBottom)
    }

    /// The code fields of agent `index`'s layout once its thread let its rows go (to its last screen, or to none), waiting for them to go.
    private static func release(_ work: Workspace, _ index: Int, from fences: Int) async throws -> Int {
        work.releaseHidden()
        try await eventuallyOnMain("agent \(index)'s layout to hold fewer code fields") {
            ListPerf.settle(work.window)
            return try work.fields(index) < fences
        }
        return try work.fields(index)
    }

    /// The last screen stayed built, so the first frame back builds no code field, and draws something at the bottom.
    @Test func aReleasedThreadsFirstFrameBackBuildsNothing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 4, cycles: 15, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        #expect(fences > 0)
        let held = try await Self.release(work, 1, from: fences)
        #expect(store.transcriptReleased && held > 0, "its last screen stays built: \(held) of \(fences) fields")

        // Select it and look at the pass that shows its layout: the deck lays the host out, and nothing is built in it.
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        work.vm.selectAgent(work.agents[1].agent.id)
        var passes = 0
        while try work.host(1)?.isHidden != false, passes < 50 {
            ListPerf.settle(work.window)
            passes += 1
        }
        #expect(SHRenderProbe.count("deck.flipLayout") == 1, "the deck laid the host out once as it showed it")
        #expect(try work.host(1)?.isHidden == false, "the layout is shown after \(passes) passes")
        #expect(SHRenderProbe.count("code.nativeCreated") == 0, "no code field is built to show it: \(SHRenderProbe.counts)")
        #expect(try work.fields(1) == held, "the same fences are on screen as a moment ago")
        let scroll = try #require(try work.transcript(1))
        let frame = Self.drawing(work.window, in: scroll)
        #expect(frame.ink > 0, "the thread draws something in its first frame")
        #expect(frame.longestBlankBand <= ThreadBlankScreenTests.blankBandLimit, "no blank stretch of \(frame.longestBlankBand) points")
        #expect(try work.distanceFromTail(1).map { abs($0) < 2 } == true, "at the bottom of the thread")
    }

    /// The rest comes back above the last screen over the frames that follow, a step of rows at a time: the end of the thread stays
    /// where it was in every one, none of them is blank, and in the end every row is drawn.
    @Test func theRestCompletesBottomUpWithoutMovingTheTail() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        // Thirty-six rows: the last thirty are the eager tail, and the six above them are a lazy stack's.
        let work = try await Workspace.open(2, replies: 18, cycles: 4, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        #expect(fences > 0 && store.rows.count == 36)
        let held = try await Self.release(work, 1, from: fences)
        #expect(store.transcriptReleased && held < fences)

        var series: [Int] = [], tails: [CGFloat] = [], bands: [Int] = [], inks: [Int] = [], built: [Int] = []
        func sample() throws {
            let counts = ListPerf.counting { ListPerf.settle(work.window) }
            built.append(counts["code.nativeCreated", default: 0])
            series.append(try work.fields(1))
            tails.append(try work.distanceFromTail(1) ?? .infinity)
            if let scroll = try work.transcript(1) {
                let frame = Self.drawing(work.window, in: scroll)
                bands.append(frame.longestBlankBand)
                inks.append(frame.ink)
            }
        }
        work.vm.selectAgent(work.agents[1].agent.id)
        // Whole when the thread is no longer released and its fences hold still: the eager tail, which the lazy stack's edge may exceed.
        var still = 0
        do {
            try await eventuallyOnMain("every fence of the eager tail to be drawn again", timeout: .seconds(60)) {
                try sample()
                still = series.count > 1 && series.last == series.dropLast().last ? still + 1 : 0
                return try work.host(1)?.isHidden == false && !store.transcriptReleased && still >= 8
            }
        } catch {
            Issue.record("\(error): \(fences) fences, drawn \(series.suffix(40)), released \(store.transcriptReleased)")
        }
        let drawn = series.filter { $0 > 0 }
        #expect(Set(drawn).count >= 4, "the rest came back over several frames: \(drawn)")
        #expect(drawn.last.map { $0 >= fences * 9 / 10 } == true, "and all of it came back: \(drawn.last ?? 0) of \(fences)")
        #expect(drawn == drawn.sorted(), "and only ever grew: \(drawn)")
        #expect(tails.allSatisfy { abs($0) <= 1 }, "the end of the thread never moved: \(tails.map { ($0 * 10).rounded() / 10 })")
        #expect(bands.allSatisfy { $0 <= ThreadBlankScreenTests.blankBandLimit }, "no frame had a blank stretch: \(bands)")
        #expect(inks.allSatisfy { $0 > 0 }, "every frame drew something")
        // A step is a row (about 4 MiB of views at most, here a reply of 4 fields and a table or two), whatever else the frame redraws.
        #expect(built.max() ?? 0 <= 8, "no frame built more than a step of rows: \(built.prefix(40))")
        #expect(built.first == 0, "the first frame built no code field")
    }

    /// A last screen shorter than the window, above long replies: the rows it kept are the thread's end, which sits at the bottom of the
    /// window in every frame back, from the first one, with nothing under it and no jump when the rest arrives above it. The first frame
    /// has nothing above that screen yet (what comes back above it is not built before the first frame, so as not to hold the main
    /// thread); the frame after has the rest there, and no frame has a blank stretch anywhere else.
    @Test func aLastScreenShorterThanTheWindowStaysAtTheBottomInEveryFrameBack() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 18, cycles: 4, shortTail: 2, in: app)
        defer { work.window.close() }
        try await work.show(1)
        // What the thread shows when nothing was ever released: the gaps between one-line rows are blank stretches of their own.
        let natural = Self.drawing(work.window, in: try #require(try work.transcript(1))).longestBlankBand
        try await work.show(0)
        let store = work.store(1)
        let fences = try work.fields(1)
        #expect(fences > 0 && store.rows.count == 36)
        _ = try await Self.release(work, 1, from: fences)
        #expect(store.transcriptDrawn == store.keptRows && store.keptRows == 4, "the four one-line rows are all it kept: \(store.keptRows)")

        var series: [Int] = [], tails: [CGFloat] = [], bands: [Int] = [], inks: [Int] = [], bottoms: [Int] = []
        func sample() throws {
            ListPerf.settle(work.window)
            guard try work.host(1)?.isHidden == false, let scroll = try work.transcript(1) else { return }
            series.append(try work.fields(1))
            tails.append(try work.distanceFromTail(1) ?? .infinity)
            let frame = Self.drawing(work.window, in: scroll)
            bands.append(frame.longestBlankBand)
            inks.append(frame.ink)
            bottoms.append(frame.inkBottom)
        }
        work.vm.selectAgent(work.agents[1].agent.id)
        var still = 0
        do {
            try await eventuallyOnMain("the rest of the thread to be drawn again", timeout: .seconds(60)) {
                try sample()
                still = series.count > 1 && series.last == series.dropLast().last ? still + 1 : 0
                return !series.isEmpty && !store.transcriptReleased && still >= 8
            }
        } catch {
            Issue.record("\(error): \(fences) fences, drawn \(series.suffix(40)), released \(store.transcriptReleased)")
        }
        #expect(series.count >= 4, "the thread was seen over several frames: \(series.count)")
        #expect(series.last.map { $0 >= fences * 9 / 10 } == true, "and all of it came back: \(series.last ?? 0) of \(fences)")
        let limit = max(ThreadBlankScreenTests.blankBandLimit, natural)
        #expect(bands.dropFirst().allSatisfy { $0 <= limit }, "no frame after the first had a blank stretch, beyond the \(natural) of the whole thread: \(bands)")
        #expect(inks.allSatisfy { $0 > 0 }, "every frame drew something")
        #expect(tails.allSatisfy { abs($0) <= 1 }, "the scroll view stayed at the end of the thread in every frame: \(tails.map { ($0 * 10).rounded() / 10 })")
        // Where the scroll view rests is not where the rows are, when they do not fill it: the lowest thing drawn is the end of the thread.
        let bottom = bottoms.last ?? -1
        #expect(bottom > 0 && bottoms.allSatisfy { abs($0 - bottom) <= 1 }, "and the end of the thread never moved in the window: \(bottoms)")
    }

    /// A reader who scrolls up while the rest is coming back keeps the place they scrolled to: the rows stop joining the tail above
    /// them, and are there to scroll through; back at the tail, the rest comes back. Keys keep the rows off while the lazy stack's
    /// estimate of its rows settles (as it does when its rows are measured), because a reader away from the tail whose scroll view
    /// then shrinks past them is put back at the end of it.
    @Test func aReaderWhoScrollsUpDuringTheRestoreStaysWhereTheyAre() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 18, cycles: 4, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        let held = try await Self.release(work, 1, from: fences)

        work.vm.userActivity.noteEvent()
        work.vm.selectAgent(work.agents[1].agent.id)
        var first: CGFloat?, heights: [CGFloat] = []
        try await eventuallyOnMain("the lazy stack to be back and its estimate to hold still", timeout: .seconds(60)) {
            work.vm.userActivity.noteEvent()
            ListPerf.settle(work.window)
            guard try work.host(1)?.isHidden == false, !store.transcriptReleased, let now = try work.transcript(1)?.documentView?.bounds.height else { return false }
            first = first ?? now
            heights.append(now)
            return now > (first ?? now) + 50 && heights.suffix(8).count == 8 && Set(heights.suffix(8)).count == 1
        }
        let begun = try work.fields(1)
        #expect(begun < fences * 9 / 10 && begun >= held, "the rest has not come back yet: \(begun) of \(fences), from \(held)")
        let scroll = try #require(try work.transcript(1))
        let clip = scroll.contentView
        let input = work.vm.threadStores.input(for: work.agents[1].agent.id)
        for _ in 0..<6 {
            input.readerScrolled(upward: true)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: clip.bounds.origin.y - 250), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            ListPerf.settle(work.window)
        }
        var rest = clip.bounds.origin.y, still = 0
        try await eventuallyOnMain("the scrolled thread to come to rest", timeout: .seconds(30), poll: .milliseconds(30)) {
            ListPerf.settle(work.window)
            still = clip.bounds.origin.y == rest ? still + 1 : 0
            rest = clip.bounds.origin.y
            return still >= 12
        }
        let away = try #require(try work.distanceFromTail(1))
        #expect(away > 80, "the reader is \(away) points above the tail")
        let heldNow = try work.fields(1)
        #expect(heldNow < fences * 9 / 10, "the rest stopped coming back when the reader left the tail: \(heldNow) of \(fences)")

        // Nothing joins the tail above the reader for as long as they stay.
        for _ in 0..<40 { ListPerf.settle(work.window) }
        try await eventuallyOnMain("the restore to hold still", poll: .milliseconds(30)) {
            ListPerf.settle(work.window)
            return try work.fields(1) == heldNow
        }
        #expect(clip.bounds.origin.y == rest, "and the reader's place did not move: \(clip.bounds.origin.y) from \(rest)")

        // Back at the tail (scrolled down as a reader does, until the lazy rows it passes have measured), the rest comes back
        // and the end of the thread holds still.
        var landed = false
        for _ in 0..<40 where !landed {
            input.readerScrolled(upward: false)
            let bottom = (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height + scroll.contentInsets.bottom
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: bottom), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            ListPerf.settle(work.window)
            landed = try work.distanceFromTail(1).map { abs($0) <= 1 } == true
        }
        let above = try work.distanceFromTail(1) ?? .infinity
        #expect(landed, "the reader is back at the tail: \(above) points above it")
        var drawn = 0, steady = 0
        do {
            try await eventuallyOnMain("the rest to come back once the reader is at the tail", timeout: .seconds(60)) {
                ListPerf.settle(work.window)
                let now = try work.fields(1)
                steady = now == drawn ? steady + 1 : 0
                drawn = now
                return drawn >= fences * 9 / 10 && steady >= 8
            }
        } catch {
            Issue.record("\(error): \(drawn) of \(fences) fences, \(try work.distanceFromTail(1) ?? .infinity) points above the tail, released \(store.transcriptReleased)")
        }
        #expect(try work.distanceFromTail(1).map { abs($0) <= 1 } == true, "and the end of the thread is where it was")
    }

    /// A keyboard switch (⌘1-9, ⌃Tab) is a key, and the person may keep typing: the rows come back only once they stop, but the lazy stack
    /// that holds the rows above the last screen comes straight back, because it builds nothing at the tail and without it the thread
    /// seems to end where its last screen does. A key at every look, the thread's document grows by the stack's rows within a few frames
    /// while no row joins the tail; once the keys stop, the rest comes back.
    @Test func aKeyboardSwitchBringsTheLazyStackBackWhileTheKeysAreRecent() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 18, cycles: 4, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        let held = try await Self.release(work, 1, from: fences)
        #expect(store.transcriptReleased && held < fences)

        work.vm.userActivity.noteEvent()
        work.vm.selectAgent(work.agents[1].agent.id)
        var heights: [CGFloat] = [], tails: [CGFloat] = [], looks = 0
        func look() throws {
            work.vm.userActivity.noteEvent()
            ListPerf.settle(work.window)
            guard try work.host(1)?.isHidden == false, let height = try work.transcript(1)?.documentView?.bounds.height else { return }
            heights.append(height)
            tails.append(try work.distanceFromTail(1) ?? .infinity)
            looks += 1
        }
        do {
            try await eventuallyOnMain("the lazy stack's rows to be in the thread while a key comes at every look", timeout: .seconds(30), poll: .milliseconds(10)) {
                try look()
                return heights.count > 1 && heights.last.map { $0 > heights[0] + 50 } == true
            }
        } catch {
            Issue.record("\(error): the document stayed at \(heights.first ?? 0) points over \(looks) looks, drawn \(try work.fields(1)) of \(fences) fields")
        }
        let now = try work.fields(1)
        #expect(now < fences / 2, "no row joined the tail while the keys came: \(now) of \(fences) fields, from \(held)")
        #expect(tails.allSatisfy { abs($0) <= 1 }, "the end of the thread never moved: \(tails.map { ($0 * 10).rounded() / 10 })")

        // The keys stop, and the rest of the rows come back.
        var drawn = 0, steady = 0
        do {
            try await eventuallyOnMain("the rest to come back once the keys stop", timeout: .seconds(60)) {
                ListPerf.settle(work.window)
                let fields = try work.fields(1)
                steady = fields == drawn ? steady + 1 : 0
                drawn = fields
                return drawn >= fences * 9 / 10 && steady >= 8
            }
        } catch {
            Issue.record("\(error): \(drawn) of \(fences) fences, released \(store.transcriptReleased)")
        }
        #expect(try work.distanceFromTail(1).map { abs($0) <= 1 } == true, "and the end of the thread is where it was")
    }

    /// A reader who scrolls up in the moments after a keyboard switch, with keys still coming, can reach the rows above the last screen: the
    /// thread never ends where its last screen does.
    @Test func aReaderWhoScrollsUpWhileTheKeysAreRecentReachesTheOlderRows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 18, cycles: 4, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        let held = try await Self.release(work, 1, from: fences)
        #expect(store.transcriptReleased && held < fences)

        work.vm.userActivity.noteEvent()
        work.vm.selectAgent(work.agents[1].agent.id)
        var height: CGFloat?, grown = false
        try await eventuallyOnMain("the lazy stack to be back, with a key at every look") {
            work.vm.userActivity.noteEvent()
            ListPerf.settle(work.window)
            guard try work.host(1)?.isHidden == false, let now = try work.transcript(1)?.documentView?.bounds.height else { return false }
            height = height ?? now
            grown = now > (height ?? now) + 50
            return grown
        }
        let atArrival = try work.fields(1)
        let scroll = try #require(try work.transcript(1))
        let clip = scroll.contentView
        let input = work.vm.threadStores.input(for: work.agents[1].agent.id)
        var reached = false, ticks = 0, top: CGFloat = 0
        while !reached, ticks < 80 {
            work.vm.userActivity.noteEvent()
            input.readerScrolled(upward: true)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: clip.bounds.origin.y - 250), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            ListPerf.settle(work.window)
            try await Task.sleep(for: .milliseconds(10))
            ticks += 1
            top = clip.bounds.origin.y
            reached = try work.fields(1) > held
        }
        let above = try work.distanceFromTail(1) ?? .infinity, built = try work.fields(1)
        #expect(atArrival == held, "the lazy stack built nothing at the tail: \(atArrival) fields, from \(held)")
        #expect(reached, "scrolling up \(ticks) times reached rows above the last screen: \(built) fields, from \(held), \(above) points above the tail, at \(top) of the document")
        #expect(above > 80, "the reader is above the tail: \(above)")
        let rest = clip.bounds.origin.y
        for _ in 0..<20 {
            work.vm.userActivity.noteEvent()
            ListPerf.settle(work.window)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(clip.bounds.origin.y - rest) <= 1, "and nothing moved the reader while the keys came: \(clip.bounds.origin.y) from \(rest)")
    }

    /// A reader who scrolls up the moment the last screen is drawn, before the lazy stack is back, is at the tail again once it is: its
    /// height is added above them, which a scroll view not held to the tail takes as a move to the oldest rows. From there they scroll
    /// up through every row.
    @Test func aReaderWhoScrollsUpBeforeTheLazyStackIsBackComesBackToTheTailAndReachesTheOlderRows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 18, cycles: 4, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        let held = try await Self.release(work, 1, from: fences)
        #expect(store.transcriptReleased && held < fences)

        // Nothing here lets a task run: the restore's first step waits for the main actor, which the reader does not.
        work.vm.selectAgent(work.agents[1].agent.id)
        var passes = 0
        while try work.host(1)?.isHidden != false, passes < 50 {
            ListPerf.settle(work.window)
            passes += 1
        }
        let scroll = try #require(try work.transcript(1))
        let clip = scroll.contentView
        let input = work.vm.threadStores.input(for: work.agents[1].agent.id)
        let height = scroll.documentView?.bounds.height ?? 0
        func up(_ points: CGFloat) {
            input.readerScrolled(upward: true)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: clip.bounds.origin.y - points), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            ListPerf.settle(work.window)
        }
        for _ in 0..<3 { up(250) }
        let before = try #require(try work.distanceFromTail(1))
        #expect(before > 80 && scroll.documentView?.bounds.height == height, "the reader is \(before) points above the tail, in the last screen alone")

        try await eventuallyOnMain("the lazy stack to be back above the reader", timeout: .seconds(30)) {
            ListPerf.settle(work.window)
            return (scroll.documentView?.bounds.height ?? 0) > height + 50
        }
        var tail = CGFloat.infinity
        try await eventuallyOnMain("the reader to be back at the tail", timeout: .seconds(30)) {
            ListPerf.settle(work.window)
            tail = try work.distanceFromTail(1) ?? .infinity
            return abs(tail) <= 1
        }
        #expect(abs(tail) <= 1, "the reader went from \(before) points above the tail to \(tail)")

        var reached = false, ticks = 0
        while !reached, ticks < 80 {
            up(250)
            try await Task.sleep(for: .milliseconds(10))
            ticks += 1
            reached = try work.fields(1) > held
        }
        let built = try work.fields(1)
        #expect(reached, "scrolling up \(ticks) times reached rows above the last screen: \(built) fields, from \(held)")
    }

    /// A thread hidden halfway through its restore and let go of again comes back from its last screen, not from the rows it had
    /// restored: its first frame back builds nothing, as it did the first time.
    @Test func aThreadReleasedAgainHalfwayThroughItsRestoreStillBuildsNothingInItsFirstFrameBack() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(3, replies: 18, cycles: 4, in: app)
        defer { work.window.close() }
        for index in [1, 2, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        #expect(fences > 0)
        let held = try await Self.release(work, 1, from: fences)
        #expect(store.transcriptReleased && held < fences)

        // Shown, it starts to restore; some of its rows are back when a third thread takes the screen.
        work.vm.selectAgent(work.agents[1].agent.id)
        var back = held
        try await eventuallyOnMain("some of its rows to come back", timeout: .seconds(60)) {
            ListPerf.settle(work.window)
            back = try work.fields(1)
            return try work.host(1)?.isHidden == false && !store.transcriptReleased && back > held
        }
        #expect(back < fences * 9 / 10, "the restore is not done: \(back) of \(fences)")
        work.vm.selectAgent(work.agents[2].agent.id)
        var passes = 0
        while try work.host(1)?.isHidden != true, passes < 50 {
            ListPerf.settle(work.window)
            passes += 1
        }
        #expect(try work.host(1)?.isHidden == true, "the third thread is shown after \(passes) passes")

        // A pass takes its rows again, down to the last screen.
        work.releaseHidden()
        try await eventuallyOnMain("the thread to hold only its last screen again") {
            ListPerf.settle(work.window)
            guard store.transcriptDrawn == store.keptRows else { return false }
            return try work.fields(1) <= held
        }

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        work.vm.selectAgent(work.agents[1].agent.id)
        passes = 0
        while try work.host(1)?.isHidden != false, passes < 50 {
            ListPerf.settle(work.window)
            passes += 1
        }
        #expect(try work.host(1)?.isHidden == false, "the thread is shown after \(passes) passes")
        #expect(SHRenderProbe.count("deck.flipLayout") == 1, "the deck laid the host out once as it showed it")
        #expect(SHRenderProbe.count("code.nativeCreated") == 0, "no code field is built to show it, from \(back) of \(fences) it had restored: \(SHRenderProbe.counts)")
    }
}

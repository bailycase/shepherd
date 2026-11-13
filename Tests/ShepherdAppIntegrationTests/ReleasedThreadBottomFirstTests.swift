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
    private static func drawing(_ window: OffscreenWindow, in scroll: NSScrollView) -> (ink: Int, longestBlankBand: Int) {
        var region = scroll.convert(scroll.bounds, to: window.host)
        region.size.height = max(1, region.height - scroll.contentInsets.bottom - 24)
        let capture = FrameTimer.capture(window, region)
        return (capture.ink, capture.longestBlankBand)
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

    /// A reader who scrolls up while the rest is coming back keeps the place they scrolled to: the rows stop joining the tail above
    /// them, and are there to scroll through; back at the tail, the rest comes back.
    @Test func aReaderWhoScrollsUpDuringTheRestoreStaysWhereTheyAre() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let work = try await Workspace.open(2, replies: 18, cycles: 4, in: app)
        defer { work.window.close() }
        for index in [1, 0] { try await work.show(index) }
        let store = work.store(1)
        let fences = try work.fields(1)
        _ = try await Self.release(work, 1, from: fences)

        work.vm.selectAgent(work.agents[1].agent.id)
        try await eventuallyOnMain("the thread to be shown, with its restore begun", timeout: .seconds(60)) {
            ListPerf.settle(work.window)
            return try work.host(1)?.isHidden == false && !store.transcriptReleased
        }
        // The reader's hand goes onto the scroll view at once, as a wheel tick does.
        let begun = try work.fields(1)
        #expect(begun < fences * 9 / 10, "the rest has not all come back yet: \(begun) of \(fences)")
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
        let held = try work.fields(1)
        #expect(held < fences * 9 / 10, "the rest stopped coming back when the reader left the tail: \(held) of \(fences)")

        // Nothing joins the tail above the reader for as long as they stay.
        for _ in 0..<40 { ListPerf.settle(work.window) }
        try await eventuallyOnMain("the restore to hold still", poll: .milliseconds(30)) {
            ListPerf.settle(work.window)
            return try work.fields(1) == held
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

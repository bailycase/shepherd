import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The rest of what moves a thread's scroll view besides a send (`ThreadSendScrollTests`), read frame
/// by frame (`ScrollTrace`): opening a long thread, switching away and back, streaming under a
/// reader and under a thread that follows, the jump to the latest, the terminal panel, the composer
/// and the subagent tray changing the room, and the window's size. The thread is the app's own, in
/// the layout deck, over rows that differ in height (`ThreadTailFlowTests`).
///
/// They sample the real frames of a layout whose estimates move with timing, and hold on macOS 27's
/// stack (before it the thread anchors itself and strands differently, so they would only be
/// intermittent known issues there): skipped on CI, like the flows they extend.
@Suite("Thread scrolling, frame by frame", .serialized, .mainActorExclusive, .timingSensitive)
@MainActor
struct ThreadScrollAuditTests {
    typealias T = ThreadTailFlowTests
    typealias Fx = ThreadBlankScreenTests
    typealias S = ThreadSendScrollTests

    struct Case: Sendable, CustomTestStringConvertible {
        var size: CGSize
        var mix: T.Mix
        var testDescription: String { "\(Int(size.width))x\(Int(size.height)), \(mix.testDescription)" }
    }

    /// Both window sizes over rows of 3,000 pt, and the short window over rows of 9,000.
    nonisolated static let cases = T.sizes.map { Case(size: $0, mix: .moderate) } + [Case(size: T.short, mix: .giant)]

    /// A running turn whose reply grows by `steps` chunks, with a tool call every third one.
    static func stream(_ deck: T.Deck, from first: Int = 0, steps: Int, tag: String) async throws {
        for k in first..<(first + steps) {
            await deck.publish(running: true, provisional: [Fx.streamingReply(1 + k % 8)]) {
                if k % 3 == 2 { $0.all.append(Fx.tool("\(tag)-t\(k)", "bash", ["command": "swift test"], output: "ok\nok", at: S.promptAt + Double(k) * 1000)) }
            }
            try await S.wait(deck, .milliseconds(100))
        }
    }

    /// Opens the thread with a trace running from its mount.
    static func opening(_ deck: T.Deck) async throws -> ScrollTrace {
        try await eventuallyOnMain("the thread's scroll view") { deck.scrollView != nil }
        let trace = try S.trace(deck)
        trace.mark("opening")
        try await deck.open()
        return trace
    }

    // MARK: Opening and switching

    /// A long thread opens on its tail, and stays there while the stack measures the rows it guessed.
    @Test(arguments: cases)
    func aLongThreadOpensOnItsTail(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 120, configure: S.likePi) { deck in
            let trace = try await Self.opening(deck)
            defer { trace.stop() }
            try await S.wait(deck, .milliseconds(1000))
            S.expectFollowed(trace, from: "opening", c.testDescription)
        }
    }

    /// A thread whose turn ran while it was hidden is on its tail when it is shown again.
    @Test(arguments: cases)
    func aThreadSwitchedAwayAndBackWhileFollowingIsOnItsTail(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: S.likePi) { deck in
            try await deck.open()
            await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("flip-u", "Run the tests.", at: S.promptAt)) }
            try await S.wait(deck, .milliseconds(300))
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("hidden")
            deck.hide()
            try await S.wait(deck, .milliseconds(200))
            for k in 0..<4 {
                deck.host.provisional = [Fx.streamingReply(1 + k)]
                deck.host.all.append(Fx.tool("flip-t\(k)", "bash", ["command": "swift test"], output: "ok\nok", at: S.promptAt + Double(k) * 1000))
                deck.host.bump()
            }
            trace.mark("shown")
            deck.show()
            try await S.wait(deck, .milliseconds(1500))
            S.expectFollowed(trace, from: "shown", c.testDescription)
        }
    }

    /// A reader keeps their place through a switch away and back, and through the turn that streams
    /// under them: nothing moves a view the reader left.
    @Test(arguments: T.sizes)
    func aReaderKeepsTheirPlaceThroughASwitchAndAStreamingTurn(size: CGSize) async throws {
        try await T.withDeck(size: size, turns: 40, configure: S.likePi) { deck in
            try await deck.open()
            await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("rd-u", "Run the tests.", at: S.promptAt)) }
            try await S.wait(deck, .milliseconds(200))
            for _ in 0..<3 {
                deck.command(.previousTurn)
                try await S.wait(deck, .milliseconds(300))
            }
            let place = try await S.readersPlace(deck)
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("switch")
            deck.hide()
            try await S.wait(deck, .milliseconds(300))
            deck.show()
            try await S.wait(deck, .milliseconds(600))
            #expect(abs(try #require(deck.reading).offset - place) <= 4, "switching away and back moved the reader from \(Int(place)) to \(Int(deck.reading?.offset ?? 0))")
            trace.mark("streaming")
            try await Self.stream(deck, steps: 10, tag: "rd")
            await deck.publish(running: false, provisional: []) {
                $0.turnChanges = [Fx.recorded(promptAt: S.promptAt)]
                $0.all.append(Fx.reply("rd-a", Fx.prose(3, 5) + "\n\n" + Fx.code(5), at: S.promptAt + 60_000))
            }
            try await S.wait(deck, .milliseconds(800))
            #expect(abs(try #require(deck.reading).offset - place) <= 4, "the turn streaming moved the reader from \(Int(place)) to \(Int(deck.reading?.offset ?? 0))")
        }
    }

    /// Growth under a thread that follows its tail is followed, a chunk at a time and as a finished turn
    /// lands with its card.
    @Test(arguments: cases)
    func aStreamingTurnIsFollowedFromChunkToChunk(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: S.likePi) { deck in
            try await deck.open()
            await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("st-u", "Run the tests.", at: S.promptAt)) }
            try await S.wait(deck, .milliseconds(200))
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("streaming")
            try await Self.stream(deck, steps: 12, tag: "st")
            await deck.publish(running: false, provisional: []) {
                $0.turnChanges = [Fx.recorded(promptAt: S.promptAt)]
                $0.all.append(Fx.reply("st-a", Fx.prose(3, 5) + "\n\n" + Fx.code(5), at: S.promptAt + 60_000))
            }
            try await S.wait(deck, .milliseconds(1000))
            S.expectFollowed(trace, from: "streaming", c.testDescription)
        }
    }

    /// The jump to latest (⌥⌘↓ past the last turn) from far above lands on the tail.
    @Test(arguments: cases)
    func theJumpToTheLatestLandsOnTheTail(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: S.likePi) { deck in
            try await deck.open()
            for _ in 0..<4 {
                deck.command(.previousTurn)
                try await S.wait(deck, .milliseconds(300))
            }
            deck.scroll(by: -400)
            try await S.wait(deck, .milliseconds(300))
            #expect(try #require(deck.reading).distance > NativeScrollFollower.threshold, "the reader is away from the tail")
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("jump")
            for _ in 0..<12 {
                deck.command(.nextTurn)
                try await S.wait(deck, .milliseconds(300))
                if (deck.reading?.distance ?? 99) <= NativeScrollFollower.threshold { break }
            }
            try await S.wait(deck, .milliseconds(800))
            S.expectRestingOnTheTail(trace, c.testDescription)
        }
    }

    // MARK: The room around the thread changing

    /// The terminal panel opening under a running turn, growing, and closing.
    @Test(arguments: cases)
    func theTerminalPanelOpeningGrowingAndClosingKeepsTheTail(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: S.likePi) { deck in
            try await deck.open()
            await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("tp-u", "Run the tests.", at: S.promptAt)) }
            try await S.wait(deck, .milliseconds(300))
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("the panel opens")
            deck.model.panel = true
            try await Self.stream(deck, steps: 4, tag: "tp1")
            trace.mark("the panel grows")
            deck.model.panelHeight = 420
            try await Self.stream(deck, from: 4, steps: 4, tag: "tp2")
            trace.mark("the panel closes")
            deck.model.panel = false
            try await S.wait(deck, .milliseconds(1000))
            S.expectFollowed(trace, from: "the panel opens", c.testDescription)
        }
    }

    /// The composer taking a long draft, line by line, and giving it back.
    @Test(arguments: cases)
    func theComposerGrowingAndShrinkingKeepsTheTail(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: S.likePi) { deck in
            try await deck.open()
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("typing")
            for lines in [2, 4, 8, 14, 20, 8, 3, 1, 0] {
                deck.store.draft = (0..<lines).map { "Draft line \($0) with a few words on it." }.joined(separator: "\n")
                try await S.wait(deck, .milliseconds(250))
            }
            try await S.wait(deck, .milliseconds(500))
            S.expectFollowed(trace, from: "typing", c.testDescription)
        }
    }

    /// The subagent tray over the composer appearing, going on, and collapsing as the runs finish.
    @Test(arguments: cases)
    func aSubagentTrayAppearingAndCollapsingKeepsTheTail(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: S.likePi) { deck in
            deck.model.tray = true
            try await deck.open()
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("the tray appears")
            deck.host.subagents = (0..<3).map { ListFixtures.run($0, state: "running") }
            await deck.publish()
            try await S.wait(deck, .milliseconds(600))
            trace.mark("the runs finish")
            deck.host.subagents = (0..<3).map { ListFixtures.run($0, state: "complete") }
            await deck.publish()
            try await S.wait(deck, .milliseconds(600))
            trace.mark("the tray is gone")
            deck.host.subagents = []
            await deck.publish()
            try await S.wait(deck, .milliseconds(1000))
            S.expectFollowed(trace, from: "the tray appears", c.testDescription)
        }
    }

    /// The window changing size, in height and in width.
    @Test(arguments: cases)
    func resizingTheWindowKeepsTheTail(_ c: Case) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: S.likePi) { deck in
            try await deck.open()
            let trace = try S.trace(deck)
            defer { trace.stop() }
            trace.mark("resize")
            for height in [900.0, 700.0, 500.0, 800.0, 1100.0] {
                deck.resize(to: CGSize(width: c.size.width, height: height))
                try await S.wait(deck, .milliseconds(200))
            }
            for width in [1000.0, 700.0, 1400.0] {
                deck.resize(to: CGSize(width: width, height: 900))
                try await S.wait(deck, .milliseconds(200))
            }
            try await S.wait(deck, .milliseconds(800))
            S.expectFollowed(trace, from: "resize", c.testDescription)
        }
    }
}

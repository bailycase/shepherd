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

/// What a send does to a thread's scroll view, read frame by frame (`ScrollTrace`) rather than from
/// where the view ended: a long thread of rows that differ in height, in the app's layout, with a
/// host that shows a pending row for a send, queues what is sent while pi works, and can stop pi for
/// Steer now (`FlowHost`).
///
/// A thread that follows its tail owes every send two things: it never takes itself away from its
/// tail by moving up (a drawn frame whose offset fell and whose distance from the tail grew), and
/// it ends resting on it, with the last row above the composer. A reader who scrolled up is owed
/// the opposite for a follow-up that waits in Up next: the place they left.
@Suite("Thread send scrolling", .serialized, .mainActorExclusive)
@MainActor
struct ThreadSendScrollTests {
    typealias T = ThreadTailFlowTests
    typealias Fx = ThreadBlankScreenTests

    static let promptAt = Fx.base + 60_000 * 60_000

    /// A host like pi's: a queue, a pending row of its own for a send, and Steer now.
    static func likePi(_ host: T.FlowHost) {
        host.queue = NativeQueue(mode: .all)
        host.interrupts = true
    }

    /// A trace over the deck's scroll view, with the guard's word on the bottom marker.
    static func trace(_ deck: T.Deck) throws -> ScrollTrace {
        let trace = ScrollTrace(try #require(deck.scrollView))
        trace.probe = { [tailGuard = deck.tailGuard] in (tailGuard.visible.contains(ThreadView.bottomID), tailGuard.repairing) }
        return trace
    }

    /// Lays the thread out every few milliseconds for `duration`, as the app's frames do.
    static func wait(_ deck: T.Deck, _ duration: Duration) async throws {
        let end = ContinuousClock.now + duration
        repeat {
            try await Task.sleep(for: .milliseconds(8))
            deck.layout()
        } while ContinuousClock.now < end
    }

    /// Where a reader who scrolled up stands once the stack has measured the rows the jump revealed:
    /// the offset, read until it has held for a third of a second.
    static func readersPlace(_ deck: T.Deck) async throws -> CGFloat {
        var last = try #require(deck.reading).offset
        var held = 0
        let deadline = ContinuousClock.now + .seconds(10)
        while held < 3, ContinuousClock.now < deadline {
            try await wait(deck, .milliseconds(110))
            let now = try #require(deck.reading).offset
            held = now == last ? held + 1 : 0
            last = now
        }
        return last
    }

    /// What a thread that follows its tail owes whatever happens to it.
    static func expectFollowed(_ trace: ScrollTrace, from step: String? = nil, _ what: String) {
        let retreats = trace.retreats(over: 40, from: step)
        #expect(retreats.isEmpty, "\(what): the thread moved away from its tail\n\(retreats.map(String.init(describing:)).joined(separator: "\n"))\n\(trace.report(from: step))")
        expectRestingOnTheTail(trace, what)
    }

    /// The last row sits above the composer: the view rests within the follower's slack of its end.
    static func expectRestingOnTheTail(_ trace: ScrollTrace, _ what: String) {
        #expect(trace.end >= -2 && trace.end <= NativeScrollFollower.repinSlack + 1,
                "\(what): the thread rests \(Int(trace.end)) pt above its tail\n\(trace.report())")
    }

    /// pi starts the turn: the prompt becomes a message, and a reply begins with a tool call.
    static func piStartsATurn(_ deck: T.Deck, _ text: String) async {
        await deck.publish(running: true, provisional: [
            Fx.reply("provisional:assistant:1", "Step 1 of 2.", status: "streaming", at: promptAt + 1000),
            Fx.tool("r1", "bash", ["command": "step 1"], output: "", at: promptAt + 1000, status: "running", provisional: true),
        ]) { $0.piStarts("sent-u", text, at: promptAt) }
    }

    /// A running turn with a few tool calls and its reply streaming, at the tail.
    static func aRunningTurn(_ deck: T.Deck) async throws {
        await deck.publish(running: true, provisional: []) { $0.all.append(Fx.user("turn-u", "Run the tests please.", at: promptAt)) }
        try await wait(deck, .milliseconds(200))
        for step in 0..<4 {
            await deck.publish(running: true, provisional: [Fx.streamingReply(1 + step)]) {
                if step % 2 == 1 {
                    $0.all.append(Fx.tool("turn-t\(step)", "bash", ["command": "swift test"],
                                          output: (0..<(2 + step)).map { "line \($0)" }.joined(separator: "\n"), at: promptAt + Double(step) * 1000))
                }
            }
            try await wait(deck, .milliseconds(80))
        }
        try await deck.expectTail("a turn running")
    }

    /// The turn ends, and the host hands pi the message that waited in Up next: the queue empties, the
    /// turn settles into its footer and its card, a pending row appears, and pi starts it.
    static func theTurnEndsAndTheQueuedMessageGoes(_ deck: T.Deck, _ text: String, running: Bool = false) async throws {
        await deck.publish(running: false, provisional: []) {
            $0.turnChanges = [Fx.recorded(promptAt: promptAt)]
            $0.all.append(Fx.reply("turn-a", Fx.prose(3, 1) + "\n\n" + Fx.code(1), at: promptAt + 60_000))
            if let operation = $0.queue?.items.first?.id {
                $0.queue?.items = []
                $0.sent = [NativeThreadMessage.pendingSend(operationID: operation, text: text, images: 0, timestamp: promptAt + 61_000)]
            }
            $0.subagents = []
        }
        try await wait(deck, .milliseconds(200))
        await deck.publish(running: true, provisional: []) { $0.piStarts("queued-u", text, at: promptAt + 61_000) }
        try await wait(deck, .milliseconds(300))
        await deck.publish(running: true, provisional: [Fx.streamingReply(2)])
        try await wait(deck, .milliseconds(800))
    }

    // MARK: An idle thread

    struct SendCase: Sendable, CustomTestStringConvertible {
        var size: CGSize
        var mix: T.Mix
        var lines: Int
        var testDescription: String { "\(Int(size.width))x\(Int(size.height)), \(mix.testDescription), \(lines) line\(lines == 1 ? "" : "s")" }
    }

    nonisolated static let sends = T.sizes.flatMap { size in [T.Mix.moderate, .giant].flatMap { mix in [1, 6].map { SendCase(size: size, mix: mix, lines: $0) } } }

    /// pi starts the turn straight after the host took the send: the host's pending row, and 20 ms later
    /// the message and a reply with a running tool call, as a real host's answer arrives. The composer
    /// takes the draft's lines out of the card as the rows go in.
    @Test(arguments: sends)
    func aSendWhosePiStartsAtOnceKeepsTheThreadOnItsTail(_ c: SendCase) async throws {
        try await T.withDeck(size: c.size, mix: c.mix, turns: 40, configure: Self.likePi) { deck in
            try await deck.open()
            try await Self.wait(deck, .milliseconds(500))
            let trace = try Self.trace(deck)
            defer { trace.stop() }
            let text = (0..<c.lines).map { "Line \($0) of the message, which is words." }.joined(separator: "\n")
            deck.store.draft = text
            try await Self.wait(deck, .milliseconds(100))
            trace.mark("send")
            await deck.store.send()
            try await Task.sleep(for: .milliseconds(20))
            await Self.piStartsATurn(deck, text)
            try await Self.wait(deck, .milliseconds(800))
            Self.expectFollowed(trace, from: "send", c.testDescription)
        }
    }

    // MARK: A turn that is running

    enum Way: String, Sendable { case queue = "Return", steerNow = "Steer now" }

    struct RunningCase: Sendable, CustomTestStringConvertible {
        var size: CGSize
        var way: Way
        var tray = false
        var testDescription: String { "\(Int(size.width))x\(Int(size.height)), \(way.rawValue)\(tray ? ", a subagent tray open" : "")" }
    }

    nonisolated static let running = [
        RunningCase(size: T.short, way: .queue), RunningCase(size: T.short, way: .steerNow), RunningCase(size: T.short, way: .queue, tray: true),
        RunningCase(size: T.tall, way: .queue), RunningCase(size: T.tall, way: .steerNow, tray: true),
    ]

    /// Return queues the message (Up next appears above the card and the composer grows) and Steer
    /// now interrupts and sends at once; either way the thread stays on its tail, through the turn
    /// ending, the stack collapsing and the message going in.
    @Test(arguments: running)
    func aSendWhileTheAgentRunsKeepsTheThreadOnItsTail(_ c: RunningCase) async throws {
        try await T.withDeck(size: c.size, turns: 40, configure: { host in
            Self.likePi(host)
            if c.tray { host.subagents = [ListFixtures.run(0, state: "running")] }
        }) { deck in
            deck.model.tray = c.tray
            try await deck.open()
            try await Self.aRunningTurn(deck)
            let trace = try Self.trace(deck)
            defer { trace.stop() }
            let text = "Also please check the other thing."
            deck.store.draft = text
            try await Self.wait(deck, .milliseconds(200))
            trace.mark("send")
            await deck.store.send(delivery: c.way == .queue ? .followUp : .interrupt)
            try await Self.wait(deck, .milliseconds(600))
            trace.mark("the reply streams on")
            for k in 4..<8 {
                await deck.publish(running: true, provisional: [Fx.streamingReply(1 + k)])
                try await Self.wait(deck, .milliseconds(100))
            }
            trace.mark("the turn ends")
            try await Self.theTurnEndsAndTheQueuedMessageGoes(deck, text)
            Self.expectFollowed(trace, from: "send", c.testDescription)
        }
    }

    // MARK: A question in the composer's place

    /// pi asks a question mid-turn: its dock takes the card's place (taller, then gone when it is
    /// answered), and a message sent after it goes in. The thread stays on its tail through all of it.
    @Test(arguments: T.sizes)
    func aQuestionTakingTheComposersPlaceKeepsTheThreadOnItsTail(size: CGSize) async throws {
        try await T.withDeck(size: size, turns: 40, configure: Self.likePi) { deck in
            try await deck.open()
            try await Self.aRunningTurn(deck)
            let trace = try Self.trace(deck)
            defer { trace.stop() }
            trace.mark("pi asks")
            await deck.publish(running: true, provisional: [Fx.streamingReply(5)]) {
                $0.dialogs = [NativeThreadDialog(id: "d1", kind: .select, title: "How should I handle the uncommitted edits?",
                                                 options: ["Compare first (Recommended)\nDiff the 11 files.", "Leave them alone\nDeploy from a clean checkout."])]
            }
            try await eventuallyOnMain("the question to reach the composer") { deck.store.dialogs.count == 1 }
            try await Self.wait(deck, .milliseconds(600))
            trace.mark("the answer")
            await deck.publish(running: true, provisional: [Fx.streamingReply(6)]) { $0.dialogs = [] }
            try await eventuallyOnMain("the question to go") { deck.store.dialogs.isEmpty }
            try await Self.wait(deck, .milliseconds(600))
            trace.mark("the turn ends")
            await deck.publish(running: false, provisional: []) {
                $0.turnChanges = [Fx.recorded(promptAt: Self.promptAt)]
                $0.all.append(Fx.reply("turn-a", Fx.prose(3, 1) + "\n\n" + Fx.code(1), at: Self.promptAt + 60_000))
            }
            try await Self.wait(deck, .milliseconds(800))
            Self.expectFollowed(trace, from: "pi asks", "a question in the composer's place")
        }
    }

    // MARK: A reader who scrolled up

    /// A follow-up that waits in Up next leaves the reader's place alone, now and when it goes.
    @Test(arguments: T.sizes)
    func aQueuedFollowUpLeavesAReaderWhoScrolledUpWhereTheyAre(size: CGSize) async throws {
        try await T.withDeck(size: size, turns: 40, configure: Self.likePi) { deck in
            try await deck.open()
            try await Self.aRunningTurn(deck)
            for _ in 0..<3 {
                deck.command(.previousTurn)
                try await Self.wait(deck, .milliseconds(300))
            }
            let before = try await Self.readersPlace(deck)
            let trace = try Self.trace(deck)
            defer { trace.stop() }
            let text = "Also please check the other thing."
            deck.store.draft = text
            trace.mark("send")
            await deck.store.send(delivery: .followUp)
            try await Self.wait(deck, .milliseconds(500))
            #expect(abs(try #require(deck.reading).offset - before) <= 4, "queueing a message moved the reader from \(Int(before)) to \(Int(deck.reading?.offset ?? 0))")
            try await Self.theTurnEndsAndTheQueuedMessageGoes(deck, text)
            #expect(abs(try #require(deck.reading).offset - before) <= 4, "the message going in moved the reader from \(Int(before)) to \(Int(deck.reading?.offset ?? 0))")
            #expect(trace.end > NativeScrollFollower.threshold, "the reader was taken to the tail")
            // The turn that message started ends, and they come back with a send that goes in now.
            await deck.publish(running: false, provisional: []) {
                $0.all.append(Fx.reply("queued-a", "Done.", at: Self.promptAt + 100_000))
            }
            deck.store.draft = "Thanks, continue."
            await deck.store.send()
            await deck.publish(running: true, provisional: []) { $0.piStarts("after-u", "Thanks, continue.", at: Self.promptAt + 120_000) }
            try await deck.expectTail("back at the tail after sending")
        }
    }

    /// A send that goes in now re-attaches to the tail, from wherever the reader was.
    @Test(arguments: T.sizes)
    func aSendFromEarlierInTheThreadReturnsToTheTail(size: CGSize) async throws {
        try await T.withDeck(size: size, mix: .giant, turns: 40, configure: Self.likePi) { deck in
            try await deck.open()
            for _ in 0..<3 {
                deck.command(.previousTurn)
                try await Self.wait(deck, .milliseconds(300))
            }
            let trace = try Self.trace(deck)
            defer { trace.stop() }
            deck.store.draft = "Thanks, continue."
            trace.mark("send")
            await deck.store.send()
            try await Self.wait(deck, .milliseconds(20))
            await Self.piStartsATurn(deck, "Thanks, continue.")
            try await deck.expectTail("back at the tail after sending")
            try await Self.wait(deck, .milliseconds(500))
            Self.expectRestingOnTheTail(trace, "a send from earlier in the thread")
        }
    }

    // MARK: A send that does not go in

    /// A host that refuses the message: the draft stays, the thread stays where it was.
    @Test(arguments: T.sizes)
    func aRefusedSendLeavesTheThreadWhereItWas(size: CGSize) async throws {
        try await T.withDeck(size: size, turns: 40, configure: { host in
            Self.likePi(host)
            host.refuses = true
        }) { deck in
            try await deck.open()
            try await Self.wait(deck, .milliseconds(300))
            let trace = try Self.trace(deck)
            defer { trace.stop() }
            let before = try #require(deck.reading).offset
            deck.store.draft = "A message the host will not take."
            try await Self.wait(deck, .milliseconds(100))
            trace.mark("send")
            await deck.store.send()
            try await Self.wait(deck, .milliseconds(600))
            #expect(deck.store.draft == "A message the host will not take.", "the draft was kept")
            #expect(deck.store.notice != nil, "the refusal was said")
            #expect(trace.retreats(from: "send").isEmpty)
            #expect(abs(try #require(deck.reading).offset - before) <= 90, "a refused send moved the thread from \(Int(before)) to \(Int(deck.reading?.offset ?? 0))")
            Self.expectRestingOnTheTail(trace, "a refused send")
        }
    }

    /// A send while the thread loads an older page: the page arrives under a thread that is on its tail,
    /// and does not pull it up.
    @Test(arguments: T.sizes)
    func aSendWhileOlderHistoryLoadsStaysOnTheTail(size: CGSize) async throws {
        try await T.withDeck(size: size, turns: 200, configure: Self.likePi) { deck in
            try await deck.open()
            // The reader goes back to the top of what is loaded, where the next page is asked for, and
            // the host takes its time answering.
            deck.host.delay = .milliseconds(400)
            for _ in 0..<60 {
                deck.command(.previousTurn)
                try await Self.wait(deck, .milliseconds(60))
                if deck.host.olderRequests > 0 || deck.store.loadingOlder { break }
            }
            deck.store.draft = "Thanks, continue."
            let trace = try Self.trace(deck)
            defer { trace.stop() }
            trace.mark("send")
            await deck.store.send()
            deck.host.delay = .zero
            await Self.piStartsATurn(deck, "Thanks, continue.")
            try await deck.expectTail("back at the tail after sending")
            try await Self.wait(deck, .milliseconds(1200))
            Self.expectRestingOnTheTail(trace, "a send while older history loaded")
        }
    }
}

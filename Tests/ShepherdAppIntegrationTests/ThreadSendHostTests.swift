import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// What a send does to a thread's scroll view against a real server and a stub pi
/// (`RealThreadRig`): the host's own snapshots, in the host's time, over a long history whose rows
/// differ in height, in the workspace view. `ThreadSendScrollTests` plays the same sends back from a
/// fake host; the layout of a long thread is chaotic enough that what a real host's timing does to it
/// is measured here too.
///
/// Before macOS 27 the thread anchors itself to its tail and the lazy stack strands it differently
/// (`ThreadTailFlowTests`), so these are intermittent known issues there.
@Suite("Thread send scrolling against a real host", .serialized, .mainActorExclusive)
@MainActor
struct ThreadSendHostTests {
    typealias T = ThreadTailFlowTests

    /// Runs `body` over a fresh thread of 40 turns, with the known-issue gate of the other thread-layout
    /// suites.
    static func withRig(size: CGSize, mix: T.Mix, _ body: (RealThreadRig) async throws -> Void) async throws {
        let rig = try await RealThreadRig(size: size, mix: mix)
        defer { rig.close() }
        try await withKnownIssue("an anchored thread's layout strands differently before macOS 27", isIntermittent: true) {
            try await body(rig)
        } when: { T.beforeMacOS27 }
    }

    /// Steer now into a turn that is running: the host stops pi and sends the message at once. The echo,
    /// "Thinking…" and the composer's collapse land within a few frames of each other, as the guard may
    /// be walking the view; the thread must come to rest on its tail, the last row above the composer.
    /// One run in about sixteen ended 38 pt above it for good, the height of the "Thinking…" line that
    /// arrived while the guard walked: the follower stands aside then, and the repair was over once the
    /// marker was back in view.
    @Test func aSteerNowSendLeavesTheThreadRestingOnItsTail() async throws {
        // CI keeps the regression check; local runs also repeat the timing-sensitive soak.
        let runs = TimingTests.enabled ? 5 : 1
        for run in 0..<runs {
            try await Self.withRig(size: T.short, mix: .moderate) { rig in
                let trace = rig.trace
                trace.mark("first send")
                rig.store.draft = "tools:3 start the long job"
                await rig.store.send()
                try await eventuallyOnMain("the run to start") { rig.store.running }
                try await rig.wait(.milliseconds(600))
                rig.release(1)
                try await rig.wait(.milliseconds(400))
                trace.mark("steer now")
                rig.store.draft = "tools:0 and then please check this other thing"
                await rig.store.send(delivery: .interrupt)
                try await rig.wait(.milliseconds(700))
                try await eventuallyOnMain("the turn to settle", timeout: .seconds(20)) { !rig.store.running }
                try await rig.wait(.milliseconds(2500))
                ThreadSendScrollTests.expectRestingOnTheTail(trace, "run \(run)")
            }
        }
    }

    /// The first send into a freshly opened thread of tall rows, with a draft of several lines: the
    /// composer gives its lines back, the echo goes in, and the host's pi starts the turn 20 ms later.
    /// The lazy stack, which had guessed this thread's height at 39,000 pt, re-estimates it at 8,000 in the
    /// middle of that, and the view goes with it: it comes to rest about 180 pt above its tail, drawing
    /// nothing, for some 150 ms until the guard puts it back (`ThreadTailGuard`). It always ends on its tail.
    @Test func aMultilineSendIntoAThreadOfTallRowsEndsOnItsTail() async throws {
        try await Self.withRig(size: T.short, mix: .giant) { rig in
            let trace = rig.trace
            // The stub makes two tool calls for the prompt, each waiting for its file.
            rig.store.draft = "tools:2 " + (0..<6).map { "Line \($0): and then please check this, which is words." }.joined(separator: "\n")
            trace.mark("send")
            await rig.store.send()
            try await rig.wait(.milliseconds(600))
            trace.mark("tools")
            rig.release(1)
            try await rig.wait(.milliseconds(600))
            rig.release(2)
            try await rig.wait(.milliseconds(1500))
            ThreadSendScrollTests.expectRestingOnTheTail(trace, "a multi-line send")
            withKnownIssue("the lazy stack's re-estimate takes the view off its tail until the guard puts it back", isIntermittent: true) {
                #expect(trace.retreats(from: "send").isEmpty, "\(trace.report(from: "send"))")
            }
        }
    }
}

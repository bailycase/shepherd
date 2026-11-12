import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// "subagent-run-follow": a running run whose transcript gains a step at a time, the way a live one
/// does, with its screen open. A run follows its tail by landing on it whenever its content moves,
/// and a landing that runs inside the layout pass that asked for it is the same hazard as the main
/// transcript's (ios-duo-1): a lazy list that keeps re-estimating answers each one with another
/// pass. After each step it checks the run still ends above its steer field, and over all of them
/// that no more than `inPassLimit` landings ran inside a layout pass and the run never gave up
/// following. On the iPhone the run is the screen; beside the thread (iPad, an open Duo) it is the
/// side pane's, found as the trailing scroll view.
enum SubagentFollowFixture {
    /// Steps the first page holds: more than a screen of them.
    static let firstPage = 8
    /// Steps after the first page, each served to the next poll.
    static let stages = 12
    /// A pin lands inside a layout pass at most `inPassLimit` times per thread it shows.
    static let inPassCeiling = NativeTailRepin.inPassLimit
    /// A drawn transcript is mostly text on a background; a blank one has no ink.
    static let inkFloor = 0.02

    /// The step the host serves, and how many polls it has answered with it.
    private final class Polls: @unchecked Sendable {
        private let lock = NSLock()
        private var step = 0
        private var answered = 0
        func serve() -> Int { lock.withLock { answered += 1; return step } }
        func advance() { lock.withLock { step += 1; answered = 0 } }
        var served: Bool { lock.withLock { answered > 0 } }
    }

    private static let polls = Polls()

    static func hosts() -> [FixtureHostData] {
        var hosts = SubagentFixtures.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        let fallback = hosts[index].reply
        hosts[index].reply = { request in
            guard case .nativeThread(let id, _, .subagentTranscript(_, SubagentFixtures.worker, nil)) = request else { return fallback?(request) }
            return .nativeThread(id: id, result: .transcript(value: transcript(stage: polls.serve())))
        }
        return hosts
    }

    /// The worker's first page, then one more step per stage: a line of prose and a build.
    static func transcript(stage: Int) -> NativeSubagentTranscript {
        typealias F = FixtureData
        var messages = [
            F.user("w1", "Restyle the desktop native thread view and the iOS app to match the spec."),
            F.assistant("w2", "Tokens landed. Now moving the tool-row derivations into a shared presentation file so macOS and iOS use the same previews.",
                        at: 60_000),
            F.tool("w3", "read", args: #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift"}"#, output: "import Foundation", at: 90_000),
        ]
        for step in 0..<(firstPage + stage) {
            let at = 120_000 + Double(step) * 30_000
            messages.append(F.assistant("s\(step)a", "Step \(step + 1): the preview for tool kind \(step + 1) moves into the shared file, and both platforms read it from there. "
                                        + "The build runs next to catch any call site that still reaches for the old helper.", at: at))
            messages.append(F.tool("s\(step)t", "bash", args: #"{"command":"swift build --target ShepherdRemote"}"#, output: "Build complete", at: at + 10_000))
        }
        return NativeSubagentTranscript(runID: SubagentFixtures.worker, messages: messages, earlierCount: 0)
    }

    @MainActor static func follow(_ app: MobileApp) async {
        SHRenderProbe.start()
        var measured: [String] = []
        var verdicts: [(ok: Bool, line: String)] = []
        for stage in 0...stages {
            if stage > 0 { polls.advance() }
            await FixtureWindows.wait("the run's step \(stage)", seconds: 20) { polls.served && runScrollView() != nil }
            // The reply is served before the screen has taken it in.
            try? await Task.sleep(for: .milliseconds(200))
            await settle()
            let counts = SHRenderProbe.counts
            let tail = tail()
            let landings = counts["subagent.tailLanding", default: 0] + counts["subagent.tailLandingResized", default: 0]
            let inPass = counts["thread.tailLandingInPass", default: 0]
            let distance = Int((tail?.distance ?? .infinity).rounded())
            let content = Int((runScrollView()?.contentSize.height ?? 0).rounded())
            measured.append("step \(stage): \(landings) landings so far, \(inPass) of them in a layout pass, \(distance)pt above the tail of \(content)pt")
            verdicts.append((tail?.valid == true, "step \(stage): the run ends above its steer field"))
        }
        let counts = SHRenderProbe.stop()
        let inPass = counts["thread.tailLandingInPass", default: 0]
        let stalled = counts["thread.tailStalled", default: 0]
        verdicts.append((inPass <= inPassCeiling, "at most \(inPassCeiling) landings inside a layout pass (\(inPass) ran)"))
        verdicts.append((stalled == 0, "the run never stopped following (\(stalled) stalls)"))
        // Only where the run is the screen's tallest scroll view does the thread's ink measure read it.
        if let run = runScrollView(), run === FollowFixture.threadScrollView() {
            let ink = FollowFixture.transcriptInk()
            measured.append("\(Int((ink * 100).rounded()))% ink")
            verdicts.append((ink >= inkFloor, "the run draws"))
        }
        measured.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        let failed = verdicts.filter { !$0.ok }
        if let first = failed.first { FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) of \(verdicts.count) checks, the first: \(first.line)") }
        FixtureCheck.report("FIXTURE CHECK ok: \(verdicts.count) checks over \(stages + 1) steps")
    }

    /// Waits until 300 ms pass with no landing, at most 3 s: a poll's step has been laid out and landed on.
    @MainActor private static func settle() async {
        func landings() -> Int { SHRenderProbe.count("subagent.tailLanding") + SHRenderProbe.count("subagent.tailLandingResized") }
        let clock = ContinuousClock()
        let started = clock.now
        var last = landings()
        var quietSince = started
        while clock.now - started < .seconds(3), clock.now - quietSince < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(20))
            if landings() != last {
                last = landings()
                quietSince = clock.now
            }
        }
    }

    /// The run's scroll view: beside the thread it is the one furthest to the trailing edge.
    @MainActor private static func runScrollView() -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UICollectionView), !(scroll is UITextView),
               scroll.contentSize.height > scroll.bounds.height {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach(walk)
        func leading(_ scroll: UIScrollView) -> CGFloat { scroll.convert(scroll.bounds, to: nil).minX }
        return found.max { (leading($0), $0.contentSize.height) < (leading($1), $1.contentSize.height) }
    }

    /// How far the run's last line sits above the end of its content, and whether that is the
    /// bottom padding under its marker, with the offset inside the content.
    @MainActor private static func tail() -> (valid: Bool, distance: CGFloat)? {
        guard let scroll = runScrollView() else { return nil }
        let inset = scroll.adjustedContentInset
        let distance = scroll.contentSize.height + inset.bottom - scroll.contentOffset.y - scroll.bounds.height
        let minimum = min(0, scroll.contentSize.height + inset.top + inset.bottom - scroll.bounds.height)
        return (distance <= MobileLayout.gutter + NativeScrollFollower.repinSlack && distance >= minimum - NativeScrollFollower.repinSlack, distance)
    }
}

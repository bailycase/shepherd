import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    static var tailFrames: [FixtureScreen] {
        [FixtureScreen(name: "tail-frames", hosts: TailFixture.hosts(), routes: [.thread(FixtureData.ref(FixtureData.preview))],
                       prepare: TailFrames.run)]
    }
}

/// "tail-frames": how far the following thread's last row sits from where it belongs, on every
/// display frame, through what moves the viewport: the keyboard rising and falling, the composer
/// growing and shrinking under a long draft, the side pane opening and closing, and the thread
/// mounting again. The landing comes after the layout that asked for it and outside its
/// animation; this is what that costs on screen. It reports and never fails: run it on two
/// builds and compare the lines.
@MainActor
enum TailFrames {
    /// A gap this small is the tail resting; more is a frame drawn away from it.
    static let rest: CGFloat = 2
    static let cycles = 3

    static func run(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > 150 && FollowFixture.threadScrollView() != nil }
        try? await Task.sleep(for: .seconds(2))
        let draft = (1...8).map { "Line \($0) of a long message to the agent" }.joined(separator: "\n")
        await measure("idle") { await pause(0.5) }
        for cycle in 1...cycles {
            await measure("keyboard rises (\(cycle))") { FollowFixture.focusComposer(); await pause(1.5) }
            await measure("keyboard falls (\(cycle))") { FollowFixture.composerField()?.resignFirstResponder(); await pause(1.5) }
            await measure("composer grows to 8 lines (\(cycle))") { store.draft = draft; await pause(1.2) }
            await measure("composer shrinks (\(cycle))") { store.draft = ""; await pause(1.2) }
        }
        // Where the side pane docks, toggling it mounts the transcript again; elsewhere the thread
        // leaves the screen and comes back.
        guard FollowFixture.threadScrollView()?.traitCollection.horizontalSizeClass == .regular else {
            for cycle in 1...cycles {
                app.navigator.popToRoot()
                await FixtureWindows.wait("the thread to leave", seconds: 3) { FollowFixture.threadScrollView() == nil }
                await measure("thread mounts again (\(cycle))") {
                    app.navigator.open(.thread(ref))
                    await pause(2)
                }
            }
            return
        }
        for toggle in 1...(2 * cycles) {
            let word = app.navigator.sidePane.isOpen ? "closes" : "opens"
            await measure("pane \(word) (\(toggle))") {
                withSHAnimation(.pane) { app.navigator.sidePane.isOpen.toggle() }
                await pause(1.8)
            }
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func measure(_ what: String, _ action: () async -> Void) async {
        let recorder = Recorder()
        recorder.start()
        await action()
        FixtureCheck.report("FIXTURE CHECK ok: \(what): \(recorder.stop())")
    }

    /// Reads the thread's scroll view on every display frame.
    @MainActor private final class Recorder {
        /// The signed gap in points between where the last row sits and where it rests above the
        /// composer (0 on the tail, positive below it), as the model has it and as it is on screen
        /// (the presentation layer). nil: no thread on screen.
        private var frames: [(model: CGFloat, shown: CGFloat)?] = []
        private var link: CADisplayLink?
        private var scroll: UIScrollView?
        private var keyboards = 0
        private var observer: NSObjectProtocol?

        func start() {
            let ticker = Ticker { [weak self] in self?.tick() }
            let link = CADisplayLink(target: ticker, selector: #selector(Ticker.fire))
            link.add(to: .main, forMode: .common)
            self.link = link
            observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboards += 1 }
            }
        }

        private func tick() {
            if scroll?.window == nil { scroll = FollowFixture.threadScrollView() }
            guard let scroll else { return frames.append(nil) }
            let regular = scroll.traitCollection.horizontalSizeClass == .regular
            let gutter = regular ? MobileLayout.padThreadGutter : MobileLayout.gutter
            let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom
            let model = bottom - scroll.contentOffset.y - scroll.bounds.height - gutter
            let bounds = scroll.layer.presentation()?.bounds ?? scroll.bounds
            frames.append((model, bottom - bounds.origin.y - bounds.height - gutter))
        }

        func stop() -> String {
            link?.invalidate()
            link = nil
            observer.map(NotificationCenter.default.removeObserver)
            let seen = frames.compactMap { $0 }
            guard !seen.isEmpty else { return "no thread on screen in \(frames.count) frames" }
            func summary(_ gaps: [CGFloat]) -> String {
                let off = gaps.filter { abs($0) > TailFrames.rest }
                var longest = 0, run = 0
                for gap in gaps { run = abs(gap) > TailFrames.rest ? run + 1 : 0; longest = max(longest, run) }
                let worst = Int((gaps.max { abs($0) < abs($1) } ?? 0).rounded())
                return "\(off.count) off (worst \(worst)pt, longest run \(longest))"
            }
            let blank = frames.count - seen.count
            return "\(frames.count) frames, \(keyboards) keyboard events, model \(summary(seen.map(\.model))), on screen \(summary(seen.map(\.shown)))"
                + (blank > 0 ? ", \(blank) with no thread" : "")
        }
    }

    private final class Ticker: NSObject {
        let tick: () -> Void
        init(_ tick: @escaping () -> Void) { self.tick = tick }
        @objc func fire() { tick() }
    }
}

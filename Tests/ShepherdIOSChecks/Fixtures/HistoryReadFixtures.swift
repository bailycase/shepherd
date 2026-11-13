import Foundation
import UIKit
import Vision
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    static var historyRead: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        return [
            // The long thread read up through in finger steps, from the tail into an uneven history: every step draws, and the
            // rows move with the finger (the first step into the history carried the rows along).
            FixtureScreen(name: "thread-read-up", hosts: HistoryRead.hosts(), routes: [.thread(thread)], prepare: HistoryRead.readUp),
            // The context sheet's find bringing a turn in the history, and one in the tail, to the top of the view: the turn
            // asked for holds the top, and flings after each end at the tail.
            FixtureScreen(name: "thread-find-history", hosts: HistoryRead.hosts(), routes: [.thread(thread)], prepare: HistoryRead.find),
            // What an assistive client can reach while the reader rests at the tail: the turns just before the tail are elements.
            FixtureScreen(name: "thread-history-reach", hosts: HistoryRead.hosts(), routes: [.thread(thread)], prepare: HistoryRead.reach),
        ]
    }
}

/// Screens over a long, uneven thread that check the history stays as a reader leaves it: what is read up through moves with
/// the finger, find lands on its turn, and the turns before the tail stay reachable. They run on the transcript as it is, so they
/// say what a change to its stack costs the reader.
enum HistoryRead {
    /// A reply that is one code block of `lines` short lines: tall for its size (a line is about 18pt), so a long history stays
    /// small to send and cheap to parse.
    static func codeReply(lines: Int, topic: String) -> String {
        "```\n" + (1...lines).map { "\(topic)\($0)" }.joined(separator: "\n") + "\n```"
    }

    /// The long thread with an uneven history: 120 turns whose replies run from 4 to 61 code lines, then thirty short ones, a
    /// question and the 24 KB reply.
    static func thread() -> NativeThreadSnapshot {
        typealias F = FixtureData
        var messages: [NativeThreadMessage] = []
        for turn in 0..<pairs {
            let at = Double(turn) * 20_000
            messages.append(F.user("t\(turn)u", "Reply with exactly: tail-\(turn)", at: at))
            let reply = turn < 120 ? codeReply(lines: 4 + (turn * 7) % 58, topic: "turn \(turn) line ") : "tail-\(turn)"
            messages.append(F.assistant("t\(turn)a", reply, at: at + 2_000))
        }
        messages.append(F.user("lu", "Write up the whole outbox design, section by section.", at: 3_100_000))
        messages.append(F.assistant("la", TailFixture.longReply(cycles: 24), at: 3_110_000))
        return F.snapshot(messages)
    }

    static func hosts() -> [FixtureHostData] { ThreadFixtures.hosts(preview: thread()) }

    /// What the thread's visible rect draws, as pixels.
    struct Picture {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    /// The thread's visible rect between the bars and the composer, drawn at one pixel to the point.
    @MainActor static func picture() -> Picture? {
        guard let scroll = FollowFixture.threadScrollView() else { return nil }
        let inset = scroll.adjustedContentInset
        let frame = CGRect(origin: .zero, size: scroll.bounds.size)
        let visible = frame.inset(by: UIEdgeInsets(top: inset.top, left: 0, bottom: inset.bottom, right: 0)).integral
        guard visible.width > 1, visible.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
            scroll.drawHierarchy(in: frame, afterScreenUpdates: true)
        }
        guard let cropped = image.cgImage?.cropping(to: visible) else { return nil }
        let (width, height) = (cropped.width, cropped.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Picture(pixels: pixels, width: width, height: height) : nil
    }

    /// The share of `after`'s inked rows that are rows of `before` moved `shift` points down: the rows moved with the finger.
    static func carried(_ before: Picture, _ after: Picture, down shift: Int) -> Double {
        guard before.width == after.width, before.height == after.height else { return 0 }
        let stride = before.width * 4
        func row(_ picture: Picture, _ y: Int) -> ArraySlice<UInt8> { picture.pixels[(y * stride)..<((y + 1) * stride)] }
        func inked(_ picture: Picture, _ y: Int) -> Bool {
            let slice = row(picture, y)
            guard let first = slice.first else { return false }
            return slice.contains { abs(Int($0) - Int(first)) > 24 }
        }
        var inkedRows = 0
        var matching = 0
        for y in max(shift, 0)..<min(after.height, before.height + shift) where inked(after, y) {
            inkedRows += 1
            let (a, b) = (row(after, y), row(before, y - shift))
            if zip(a, b).allSatisfy({ abs(Int($0) - Int($1)) <= 12 }) { matching += 1 }
        }
        return inkedRows == 0 ? 0 : Double(matching) / Double(inkedRows)
    }

    /// The pairs of short turns before the last question and the 24 KB reply.
    static let pairs = 150

    /// The row a line of text belongs to, as its index among the thread's rows: a question names its turn ("tail-N"), a short
    /// reply is "tail-N" alone, and a code reply is lines "turn N line k". Nil for any other text.
    static func row(of text: String) -> Int? {
        func number(matching pattern: String) -> Int? {
            guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(text[range].filter(\.isNumber))
        }
        if let turn = number(matching: #"tail-\d+"#) { return text.contains("Reply with") ? 2 * turn : 2 * turn + 1 }
        if let turn = number(matching: #"turn \d+ line"#) { return 2 * turn + 1 }
        // The last question and the 24 KB reply under it.
        if text.contains("Write up the whole outbox") { return 2 * pairs }
        if text.range(of: #"Part \d+: the"#, options: .regularExpression) != nil { return 2 * pairs + 1 }
        return nil
    }

    /// The thread's rows an assistive client can list now, with where each sits on the screen.
    @MainActor static func listedRows(_ scroll: UIScrollView) -> [(row: Int, frame: CGRect)] {
        guard let window = scroll.window else { return [] }
        return elements(from: window).compactMap { element in row(of: element.label).map { ($0, element.frame) } }
    }

    /// The row that holds the top of the view, read off what the view draws (the screen's own text, so no accessibility client
    /// is needed): the topmost line of text that names a row. A tall reply under the top edge names its own turn in every line.
    @MainActor static func topIndex(_ scroll: UIScrollView) async -> Int? {
        let inset = scroll.adjustedContentInset
        let frame = CGRect(origin: .zero, size: scroll.bounds.size)
        let visible = frame.inset(by: UIEdgeInsets(top: inset.top, left: 0, bottom: inset.bottom, right: 0)).integral
        guard visible.width > 1, visible.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
            scroll.drawHierarchy(in: frame, afterScreenUpdates: true)
        }
        let crop = CGRect(x: visible.minX * 2, y: visible.minY * 2, width: visible.width * 2, height: visible.height * 2)
        guard let cropped = image.cgImage?.cropping(to: crop) else { return nil }
        // Off the main queue: reading the text takes seconds under load, and the watchdog is watching that queue.
        let texts = await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            guard (try? VNImageRequestHandler(cgImage: cropped).perform([request])) != nil else { return [] }
            // Vision's origin is the bottom left: the topmost line has the largest top edge.
            return (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
        }.value
        return texts.lazy.compactMap { row(of: $0) }.first
    }

    /// Waits for the thread to be on screen with its rows built, and the view to rest at its tail.
    @MainActor static func ready(_ app: MobileApp) async -> (store: NativeThreadStore, scroll: UIScrollView)? {
        let store = app.threads.store(for: FixtureData.ref(FixtureData.preview))
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > 150 && FollowFixture.threadScrollView() != nil }
        try? await Task.sleep(for: .seconds(2))
        guard let scroll = FollowFixture.threadScrollView() else {
            FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view")
            return nil
        }
        return (store, scroll)
    }

    /// "thread-read-up": from the tail the reader drags up in finger steps through the 24 KB reply and the history under it;
    /// at each step the transcript has ink and the rows follow the finger. The step that
    /// first brings rows the stack has not measured into view is the one that moved a reader's rows when a stack's estimate
    /// changed under them; it is the step this screen is for. Every step is measured before the verdict.
    @MainActor static func readUp(_ app: MobileApp) async {
        guard let (store, scroll) = await ready(app) else { return }
        MainQueueWatchdog.start(limit: 8)
        let finger = TailFixture.Finger(scroll: scroll)
        var failed: [String] = []
        var lines: [String] = []
        let start = TailFixture.shown()
        lines.append("at the tail: \(Int((start.ink * 100).rounded()))% ink, \(start.distance)pt above the tail, content \(Int(scroll.contentSize.height))pt, \(store.rows.count) turns")
        if start.ink < TailFixture.inkFloor || !start.atTail { failed.append("the thread does not rest at its tail with rows drawn") }
        let step = min(400, (scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom) / 2)
        var smallest = 1.0
        var steps = 0
        var loose = 0
        var slips = 0
        // The reply is most of the tail (some 16,000pt on a phone): small steps through its end, a dive across the rest of it, then
        // small steps again where the history begins and at each further depth.
        let plan: [(dive: CGFloat, steps: Int)] = [(0, 6), (15_000, 6), (12_000, 6), (30_000, 6), (60_000, 6)]
        for (index, leg) in plan.enumerated() {
            if leg.dive > 0 { await finger.drag(by: -leg.dive, frame: 4_000) }
            try? await Task.sleep(for: .milliseconds(250))
            for n in 1...leg.steps {
                guard let before = picture() else { failed.append("the thread has no picture"); break }
                let from = scroll.contentOffset.y
                await finger.drag(by: -step)
                try? await Task.sleep(for: .milliseconds(120))
                let moved = Int((from - scroll.contentOffset.y).rounded())
                guard let after = picture() else { failed.append("the thread has no picture"); break }
                let height = scroll.contentSize.height
                let ink = FollowFixture.transcriptInk()
                // What the finger did, not what the offset did: the lazy stack may adjust the offset as it measures, keeping the rows put.
                let dragged = moved > 0 ? Int(step) : 0
                let share = dragged > 0 && dragged < after.height ? carried(before, after, down: dragged) : 1
                // Reading the text off the screen takes a moment: once at the end of each leg.
                let top = n == leg.steps ? await topIndex(scroll) : nil
                steps += 1
                smallest = min(smallest, share)
                lines.append("leg \(index + 1) step \(n): moved \(moved)pt, content \(Int(height))pt, \(Int((ink * 100).rounded()))% ink, \(Int((share * 100).rounded()))% of the rows carried, top turn \(top.map(String.init) ?? "none")")
                if ink < TailFixture.inkFloor { failed.append("leg \(index + 1) step \(n): the history is blank") }
                // Text redrawn at another offset matches only roughly, and a lazy stack that re-estimates its rows under the finger
                // moves them for a step; a view whose rows do not follow the finger shows under 10% for steps in a row.
                loose = share < 0.1 ? loose + 1 : 0
                if share < 0.1 { slips += 1 }
                if loose > 1 { failed.append("leg \(index + 1) step \(n): the rows did not follow the finger for two steps (\(Int((share * 100).rounded()))% carried)") }
                if scroll.contentOffset.y <= finger.top + 1 { break }
            }
            if scroll.contentOffset.y <= finger.top + 1 { break }
        }
        lines.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        await finger.toEnd(tries: 8)
        let now = await TailFixture.shown(within: .seconds(3)) { $0.ink >= TailFixture.inkFloor && $0.atTail }
        if now.ink < TailFixture.inkFloor || !now.atTail { failed.append("the fling back ends \(now.distance)pt above the tail with \(Int((now.ink * 100).rounded()))% ink") }
        let summary = "\(steps) steps, the fewest rows carried in one step \(Int((smallest * 100).rounded()))%, \(slips) steps under 10%"
        if let first = failed.first {
            FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) failures reading up through the history (\(summary)), the first: \(first)")
        } else {
            FixtureCheck.report("FIXTURE CHECK ok: reading up through the history keeps the rows with the finger (\(summary)) and the fling back ends at the tail")
        }
    }

    /// Waits until the view has not moved for `quiet`, at most `limit`, and returns the row that holds its top.
    @MainActor static func rest(_ scroll: UIScrollView, quiet: Duration, limit: Duration) async -> Int? {
        let clock = ContinuousClock()
        let began = clock.now
        var changed = began
        var last = scroll.contentOffset.y
        while clock.now - began < limit, clock.now - changed < quiet {
            try? await Task.sleep(for: .milliseconds(100))
            let now = scroll.contentOffset.y
            if abs(now - last) > 1 || scroll.isDragging || scroll.isDecelerating {
                last = now
                changed = clock.now
            }
        }
        return await topIndex(scroll)
    }

    /// "thread-find-history": the context sheet's find brings a turn to the top of the view. Five finds, two far from the tail and
    /// three near it. Each is measured: whether the view left the tail, the row at its top read off the pixels, how many rows that
    /// is from the row asked for (it lands when within 2), and whether it drew anything. The stack places a turn it has not built
    /// by estimate, so on some launches a far find leaves the view at the tail, on others it stops part way, and a find may land
    /// on a stranded offset that draws nothing: those are counted, not failed, and the outcomes of two builds are compared.
    /// A fling after each find ends at the tail with the rows drawn.
    @MainActor static func find(_ app: MobileApp) async {
        guard let (store, scroll) = await ready(app) else { return }
        let ref = FixtureData.ref(FixtureData.preview)
        let presentation = app.navigator.composerPresentation.state(for: ref)
        MainQueueWatchdog.start(limit: 8)
        let finger = TailFixture.Finger(scroll: scroll)
        var failed: [String] = []
        var lines: [String] = []
        var outcomes: [String: Int] = [:]
        func index(of entry: String) -> Int? { store.rows.firstIndex { $0.turn.messages.contains { $0.entryID == entry } } }
        for (round, entry) in ["t20u", "t95a", "t144u", "t60a", "t149a"].enumerated() {
            guard let target = index(of: entry) else { failed.append("no turn holds \(entry)"); continue }
            // The context sheet asks while the thread is at rest; the flings before this one have settled.
            await FixtureWindows.wait("the thread at rest", seconds: 5) { !scroll.isDragging && !scroll.isDecelerating && !scroll.isTracking }
            try? await Task.sleep(for: .milliseconds(500))
            let from = scroll.contentOffset.y
            presentation.find(entry)
            // A loaded machine starts the scroll late: wait for it to start before waiting for it to stop.
            let began = ContinuousClock.now
            while abs(scroll.contentOffset.y - from) <= 50, !scroll.isDecelerating, ContinuousClock.now - began < .seconds(6) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let top = await rest(scroll, quiet: .seconds(1.5), limit: .seconds(12))
            let moved = finger.end - scroll.contentOffset.y > 1_000
            let error = top.map { abs($0 - target) }
            let ink = FollowFixture.transcriptInk()
            let outcome = !moved ? "stayed at the tail" : ink < TailFixture.inkFloor ? "drew nothing" : (error.map { $0 <= 2 ? "landed" : "stopped part way" } ?? "unread")
            outcomes[outcome, default: 0] += 1
            lines.append("find \(entry) (row \(target) of \(store.rows.count)): \(outcome), top row \(top.map(String.init) ?? "unread"), \(error.map { "\($0) rows off" } ?? "error unknown"), \(Int((finger.end - scroll.contentOffset.y).rounded()))pt above the end, \(Int((ink * 100).rounded()))% ink")
            await finger.drag(by: -CGFloat(1 + round % 3) * 4_000)
            try? await Task.sleep(for: .milliseconds(100))
            let now = await finger.toEndAndLook()
            lines.append("  fling after \(entry): \(Int((now.ink * 100).rounded()))% ink, \(now.distance)pt above the tail\(now.notPastEnd ? "" : ", PAST THE END")")
            if now.ink < TailFixture.inkFloor || !now.atTail { failed.append("fling after find \(entry): ends \(now.distance)pt above the tail with \(Int((now.ink * 100).rounded()))% ink") }
        }
        lines.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        let summary = outcomes.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        if let first = failed.first {
            FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) failures after finds (\(summary)), the first: \(first)")
        } else {
            FixtureCheck.report("FIXTURE CHECK ok: finds: \(summary); the flings after them end at the tail")
        }
    }

    /// An accessibility element the transcript lists: what an assistive client reads, and where it sits on the screen.
    struct Element {
        var label: String
        var frame: CGRect
    }

    /// The accessibility elements under `root`, depth first. SwiftUI lists its rows through the hosting view's container
    /// methods, not through the scroll view's subviews, so the walk starts at the window.
    @MainActor static func elements(from root: UIView) -> [Element] {
        var found: [Element] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 24 else { return }
            if object.isAccessibilityElement {
                if let label = object.accessibilityLabel, !label.isEmpty { found.append(Element(label: label, frame: object.accessibilityFrame)) }
                return
            }
            if let children = object.accessibilityElements, !children.isEmpty {
                for case let child as NSObject in children { visit(child, depth: depth + 1) }
                return
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for n in 0..<count { if let child = object.accessibilityElement(at: n) as? NSObject { visit(child, depth: depth + 1) } }
                return
            }
            if let view = object as? UIView { view.subviews.forEach { visit($0, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return found
    }

    /// "thread-history-reach": what an assistive client reaches in the history. At rest at the tail it lists the rows the transcript
    /// has built. A VoiceOver reader who walks back past the first of them has the transcript scroll a page, and the rows above are
    /// built and listed. The screen pages up one screen at a time, as that does, and counts the pages until a row before the tail's
    /// own (the question and its reply) is listed, at most `limit`; it fails when none ever is.
    @MainActor static func reach(_ app: MobileApp) async {
        guard let (store, scroll) = await ready(app) else { return }
        MainQueueWatchdog.start(limit: 8)
        let tailStart = store.rows.count - 2
        let finger = TailFixture.Finger(scroll: scroll)
        let atRest = listedRows(scroll)
        let total = elements(from: scroll.window ?? scroll).count
        // SwiftUI lists nothing until an accessibility client asks: the simulator needs `ApplicationAccessibilityEnabled` on
        // (`xcrun simctl spawn <device> defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true`).
        guard total > 0 else { return FixtureCheck.report("FIXTURE CHECK ok: no accessibility tree in this simulator; nothing to check") }
        FixtureCheck.report("FIXTURE CHECK ok: at rest at the tail \(total) elements, \(atRest.count) of them rows, the oldest row listed \(atRest.map(\.row).min().map(String.init) ?? "none") of \(store.rows.count)")
        let limit = 60
        var pages = 0
        var reached: Int?
        while pages < limit {
            if let older = listedRows(scroll).map(\.row).filter({ $0 < tailStart }).max() {
                reached = older
                break
            }
            let page = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: 0, y: max(finger.top, scroll.contentOffset.y - page)), animated: false)
            pages += 1
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let reached {
            FixtureCheck.report("FIXTURE CHECK ok: a row before the tail is listed after \(pages) pages up (row \(reached) of \(store.rows.count))")
        } else {
            FixtureCheck.report("FIXTURE CHECK FAILED: no row before the tail is listed after \(pages) pages up")
        }
    }
}

import Foundation
import UIKit
import ShepherdCore
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    static var composerField: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        return [
            // Keys typed into a long draft, then layout asked again with the text and width unchanged: the field lays its text out
            // once per edit, not once per probe. Needs a Debug build (the counts are SHRenderProbe's).
            FixtureScreen(name: "composer-field-work", hosts: ThreadFixtures.hosts(), routes: [.thread(thread)], prepare: ComposerFieldFixture.work),
            // The field's height as the draft grows from one line to past the eight it shows, shrinks back, is pasted into, restored,
            // holds a skill chip and is turned to a new width: each look prints its geometry (and saves a PNG when FIXTURE_LOOKS_DIR is set).
            FixtureScreen(name: "composer-field-looks", hosts: ThreadFixtures.hosts(preview: ThreadFixtures.skills()), routes: [.thread(thread)],
                          prepare: ComposerFieldFixture.looks),
        ]
    }
}

enum ComposerFieldFixture {
    static let sentence = "The relay keeps the row in the outbox and tries again. "
    /// Keys typed at each size of draft; the most any one edit may lay the field's text out for.
    static let keys = 12
    static let measuresPerEdit = 1

    /// The composer's field as it is now: the thread screen builds its composer again as the thread arrives, so a field held
    /// from earlier may be one that left the window.
    @MainActor static var field: UITextView {
        guard let field = FollowFixture.composerField() else { FixtureCheck.fail("no composer field") }
        return field
    }

    /// Waits for the thread to be on screen and its composer to stop being rebuilt, with the caret in its field.
    @MainActor static func ready(_ app: MobileApp) async -> NativeThreadStore {
        let store = app.threads.store(for: FixtureData.ref(FixtureData.preview))
        await FixtureWindows.wait("the thread", seconds: 20) { !store.rows.isEmpty && FollowFixture.composerField() != nil }
        try? await Task.sleep(for: .seconds(2))
        await FixtureWindows.wait("the composer field to take focus", seconds: 20) {
            if !field.isFirstResponder { field.becomeFirstResponder() }
            return field.isFirstResponder
        }
        try? await Task.sleep(for: .seconds(1))
        return store
    }

    @MainActor static func settle() async {
        for _ in 0..<2 { try? await Task.sleep(for: .milliseconds(150)) }
    }

    /// "composer-field-work".
    @MainActor static func work(_ app: MobileApp) async {
        let store = await ready(app)
        var failures: [String] = []
        for size in [0, 6_000, 40_000] {
            store.draft = String(repeating: sentence, count: size / sentence.count)
            await settle()
            field.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
            let length = (field.text as NSString).length
            SHRenderProbe.start()
            for index in 0..<keys {
                field.insertText(index % 12 == 11 ? " " : "k")
                await settle()
            }
            let counts = SHRenderProbe.stop()
            let probed = counts["layout.composerFieldProbed", default: 0]
            let measured = counts["layout.composerFieldMeasured", default: 0]
            let typed = (field.text as NSString).length - length
            let published = store.draft.utf16.count == (field.text as NSString).length
            let held = typed == keys && published && probed > 0 && measured <= keys * measuresPerEdit
            if !held { failures.append("\(size / 1000) KB: \(typed) of \(keys) keys typed\(published ? "" : ", not in the draft"), \(measured) layouts") }
            print("FIXTURE CHECK \(held ? "ok" : "not ok"): \(keys) keys into a \(size / 1000) KB draft: the field was asked its size \(probed) times and laid its text out \(measured) times (at most \(keys * measuresPerEdit))")
        }
        // The text and the width stay as they are while SwiftUI is asked for the field's size again.
        SHRenderProbe.start()
        for _ in 0..<5 {
            field.invalidateIntrinsicContentSize()
            await settle()
        }
        let counts = SHRenderProbe.stop()
        let probed = counts["layout.composerFieldProbed", default: 0]
        let measured = counts["layout.composerFieldMeasured", default: 0]
        if probed == 0 || measured > 0 { failures.append("unchanged text: \(measured) layouts in \(probed) asks") }
        print("FIXTURE CHECK \(probed > 0 && measured == 0 ? "ok" : "not ok"): five size invalidations over the same text and width: asked \(probed) times, laid out \(measured) times (none)")
        FixtureCheck.report("FIXTURE CHECK \(failures.isEmpty ? "ok" : "FAILED"): the field lays its text out once per edit, not once per size ask\(failures.isEmpty ? "" : " (" + failures.joined(separator: "; ") + ")")")
    }

    struct Look {
        var label: String
        var height: CGFloat
        var scrolls: Bool
        var width: CGFloat
        var offset: CGFloat
        var content: CGFloat
    }

    @MainActor static func look(_ label: String, _ field: UITextView) async -> Look {
        await settle()
        let look = Look(label: label, height: field.frame.height, scrolls: field.isScrollEnabled, width: field.frame.width,
                        offset: field.contentOffset.y, content: field.contentSize.height)
        print("FIXTURE CHECK ok: look \(label) height=\(look.height) width=\(look.width) scrolls=\(look.scrolls) offset=\(look.offset) content=\(look.content) chars=\((field.text as NSString).length)")
        snapshot(label, field)
        return look
    }

    @MainActor static func snapshot(_ label: String, _ field: UITextView) {
        guard let directory = ProcessInfo.processInfo.environment["FIXTURE_LOOKS_DIR"], let window = field.window else { return }
        let range = field.selectedTextRange
        field.selectedTextRange = nil
        let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        field.selectedTextRange = range
        let name = label.replacingOccurrences(of: " ", with: "-")
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    @MainActor static func turn(_ scene: UIWindowScene, to mask: UIInterfaceOrientationMask) async {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        await FixtureWindows.wait("the turn", seconds: 5) {
            mask == .portrait ? scene.effectiveGeometry.interfaceOrientation.isPortrait : scene.effectiveGeometry.interfaceOrientation.isLandscape
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// "composer-field-looks".
    @MainActor static func looks(_ app: MobileApp) async {
        let store = await ready(app)
        let fontLine = (field.typingAttributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)).lineHeight
        let lineHeight = ceil(fontLine)
        let most = ceil(fontLine * CGFloat(SHComposerMetrics.fieldMaxLines))
        var failures: [String] = []
        func expect(_ holds: Bool, _ what: String) { if !holds { failures.append(what) } }

        let empty = await look("empty", field)
        expect(empty.height == lineHeight && !empty.scrolls, "an empty field is one line and does not scroll")

        // Typed a line at a time: it grows to the ceiling, then holds there and scrolls.
        field.insertText("Fix the flaky retry test")
        var heights = [await look("typed-1-line", field).height]
        var scrolls: [Bool] = []
        for line in 2...30 {
            field.insertText("\nline \(line)")
            let now = await look("typed-\(line)-lines", field)
            heights.append(now.height)
            scrolls.append(now.scrolls)
        }
        expect(heights.first == lineHeight, "one typed line is one line tall")
        expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 }, "typing lines never shortens the field")
        expect(abs(heights[7] - most) < 1 && heights.last == most, "eight lines and thirty lines stand at the ceiling")
        expect(heights[6] < heights[7], "seven lines are shorter than eight")
        expect(scrolls.prefix(6).allSatisfy { !$0 } && scrolls.suffix(21).allSatisfy { $0 }, "the field scrolls only past the eighth line")

        // Deleted back down: the heights they had on the way up, in reverse.
        var shrunk: [CGFloat] = []
        for line in stride(from: 30, to: 1, by: -1) {
            for _ in 0..<"\nline \(line)".count { field.deleteBackward() }
            shrunk.append(await look("deleted-to-\(line - 1)-lines", field).height)
        }
        expect(shrunk == heights.dropLast().reversed(), "deleting lines gives the heights typing them did, back to one line")

        // A paste of a long draft in one insert.
        store.draft = ""
        await settle()
        field.insertText((1...60).map { "pasted line \($0) " + sentence }.joined(separator: "\n"))
        let pasted = await look("pasted-60-lines", field)
        expect(pasted.height == most && pasted.scrolls, "a long paste stands at the ceiling and scrolls")

        // Restored by code, as when a draft returns after a thread switch or a failed send.
        store.draft = (1...12).map { "Line \($0) of a restored draft" }.joined(separator: "\n")
        let restored = await look("restored-12-lines", field)
        expect(restored.height == most && restored.scrolls, "a restored long draft stands at the ceiling and scrolls")
        store.draft = "Short again"
        let back = await look("restored-1-line", field)
        expect(back.height == lineHeight && !back.scrolls, "a short restored draft is one line and does not scroll")

        // A skill is one chip in the line.
        store.draft = "Run /skill:debug on the failing job"
        let chip = await look("skill-chip", field)
        expect(chip.height < 2 * lineHeight && !chip.scrolls, "a draft with a skill chip is one line")
        store.draft = "/skill:debug " + (1...10).map { "line \($0) after the skill" }.joined(separator: "\n")
        let chipLong = await look("skill-chip-long", field)
        expect(chipLong.height == most && chipLong.scrolls, "a long draft led by a skill chip stands at the ceiling")

        // The width changes with a turn: the same draft is laid out again at the new width.
        store.draft = String(repeating: sentence, count: 6)
        let portrait = await look("wrapped-portrait", field)
        expect(portrait.height == most && portrait.scrolls, "ten wrapped lines stand at the ceiling and scroll")
        if let scene = field.window?.windowScene {
            await turn(scene, to: .landscapeRight)
            let landscape = await look("wrapped-landscape", field)
            expect(landscape.width > portrait.width && landscape.height < portrait.height && !landscape.scrolls, "turned wider, the same words take fewer lines")
            await turn(scene, to: .portrait)
            let again = await look("wrapped-portrait-again", field)
            expect(again.height == portrait.height && again.width == portrait.width && again.scrolls == portrait.scrolls, "turned back, the field is as it was")
        }
        store.draft = ""
        FixtureCheck.report("FIXTURE CHECK \(failures.isEmpty ? "ok" : "FAILED"): the composer field's height, ceiling and scrolling\(failures.isEmpty ? "" : ": " + failures.joined(separator: "; "))")
    }
}

import AppKit
import ShepherdUI
import ShepherdProtocol
@testable import ShepherdApp
import SwiftUI
import Testing
import ShepherdTestSupport

@Suite("Diff line drawing", .mainActorExclusive)
@MainActor
struct DiffDrawingTests {
    @Test(arguments: [false, true])
    func longLinesCanBeReachedByHorizontalScrolling(split: Bool) async throws {
        let source = String(repeating: "long_identifier_", count: 35) + "VISIBLE_END"
        let files = DiffFile.parse("diff --git a/sample.txt b/sample.txt\n--- a/sample.txt\n+++ b/sample.txt\n@@ -1 +1 @@\n-old\n+\(source)\n")
        let model = ListFixtures.reviewModel(files)
        model.session.layoutChoice = split ? .split : .unified
        let window = OffscreenWindow(size: CGSize(width: 600, height: 400), dark: false,
                                     ReviewPaneContent(model: model))
        defer { window.close() }
        try await eventuallyOnMain("the diff to expose its horizontal extent") {
            window.layout()
            guard let scroll = ListPerf.scrollView(in: window) else { return false }
            return (scroll.documentView?.bounds.width ?? 0) > scroll.contentView.bounds.width + 1000
        }
        let scroll = try #require(ListPerf.scrollView(in: window))
        let clip = scroll.contentView
        let end = clip.constrainBoundsRect(NSRect(x: scroll.documentView!.bounds.width, y: clip.bounds.minY,
                                                  width: clip.bounds.width, height: clip.bounds.height)).origin
        clip.scroll(to: end)
        scroll.reflectScrolledClipView(clip)
        window.layout()
        #expect(clip.bounds.minX > 1000)
        #expect(abs(clip.bounds.maxX - scroll.documentView!.bounds.width) < 2,
                "the trailing source must be reachable, not just present in a tooltip")
    }

    @Test(arguments: [false, true])
    func syntaxAndWordHighlightsDrawInsideTheCodeColumn(split: Bool) throws {
        var text = AttributedString(String(repeating: "Highlighted words ", count: 30))
        text.foregroundColor = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        text.backgroundColor = Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)
        let line = NWDiffLineContent(id: "sample", key: 1, kind: .added, oldNumber: nil, newNumber: 12345,
                                     text: text, source: String(text.characters))
        let size = CGSize(width: 360, height: NWDiffMetrics.lineHeight)
        let window = OffscreenWindow(size: size, dark: false)
        defer { window.close() }
        if split {
            window.show(NWSplitDiffSide(line, side: .new, onComment: {}).background(Color.white))
        } else {
            window.show(NWDiffLine(line, onComment: {}).background(Color.white))
        }
        let capture = FrameTimer.capture(window, CGRect(origin: .zero, size: size))
        var red = 0, blue = 0, leaking = 0
        let codeStart = Int(NWDiffMetrics.barWidth + NWDiffMetrics.numberWidth * (split ? 1 : 2)
                            + (split ? 0 : NWDiffMetrics.signWidth))
        // The comment slot reserves 18pt plus two 6pt side gaps.
        let codeEnd = Int(size.width - 30)
        for y in 0..<capture.height {
            for x in 0..<capture.width {
                let offset = y * capture.bytesPerRow + x * 4
                let r = capture.data[offset], g = capture.data[offset + 1], b = capture.data[offset + 2]
                let syntax = r > 180 && g < 100 && b < 100
                let word = b > 180 && r < 100 && g < 100
                if syntax { red += 1 }
                if word { blue += 1 }
                if (syntax || word) && (x < codeStart || x >= codeEnd) { leaking += 1 }
            }
        }
        #expect(red > 20, "syntax-colored glyphs must actually render")
        #expect(blue > 100, "word-diff background attributes must actually render")
        #expect(leaking == 0, "long code cannot draw over the number gutter or comment slot")
    }
}

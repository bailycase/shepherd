import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import DesignSurfaceKit

/// A board leaving the canvas, rendered offscreen by the real runtime: baked to a standalone
/// page, drawn at @2x, and printed as PDF pages (fixed and flow).
@MainActor
@Suite(.mainActorExclusive)
struct DesignBoardExportTests {
    /// A flow document on Letter: `paragraphs` blocks of text, 60px apart, with an image in the middle.
    static func flowBoard(paragraphs: Int) -> String {
        let text = (0..<paragraphs).map { #"<p style="margin: 0 0 24px; font-size: 16px; line-height: 24px">Paragraph \#($0). The quick brown fox jumps over the lazy dog, again and again, until the line wraps onto the next one and the one after.</p>"# }
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Report</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>html,body{margin:0;background:#fdfbf7}</style></helmet>
        <div style="width: 816px; box-sizing: border-box; padding: 72px">
        <h1 style="margin: 0 0 24px">Report</h1>
        \(text.prefix(paragraphs / 2).joined(separator: "\n"))
        <svg width="400" height="300" viewBox="0 0 400 300"><rect width="400" height="300" fill="#ccc"/></svg>
        \(text.dropFirst(paragraphs / 2).joined(separator: "\n"))
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":816,"height":1056}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    @Test func aStandalonePageIsWhatTheBoardDrawsWithNoRuntime() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()

        let page = try await view.staticPage()

        #expect(page.hasPrefix("<!doctype html>\n<html lang=\"en\">"))
        #expect(page.contains("<title>Checkout</title>"))
        #expect(page.contains("body{margin:0;font-family:system-ui,sans-serif;background:#ffffff}"), "the hoisted helmet")
        #expect(page.contains(">Checkout</h1>") && page.contains("Second · 1"), "what the logic drew")
        #expect(!page.localizedCaseInsensitiveContains("<script"), "no runtime, no logic")
        #expect(!page.contains("data-dc-") && !page.contains("x-dc{display"), "none of Shepherd's stamps")
        #expect(!page.contains("support.js") && !page.contains("<x-dc"))
        #expect(!page.contains("{{"), "no holes left")
    }

    @Test func anImageIsTwiceTheBoardsSize() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()

        let image = try await view.image(scale: 2)

        #expect(image.width == 800 && image.height == 600)
        let png = try DesignImageFile.png(image)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func aFixedBoardIsOnePageAtItsFramesSize() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()

        let pdf = try await view.pdf(.fixed)

        // 400 × 300 CSS px at 96 to the inch: 300 × 225 points.
        #expect(DesignPDF.pages(pdf) == [CGSize(width: 300, height: 225)])
    }

    @Test func aFlowDocumentRunsOntoLetterPages() async throws {
        let harness = try BoardHarness(files: ["Report.dc.html": Self.flowBoard(paragraphs: 60)])
        let view = try harness.view("Report.dc.html", size: CGSize(width: 816, height: 1056))
        try await view.load()
        let layout = try #require(try await view.printLayout())
        #expect(layout.height > 3000)
        let expected = DesignPrint.pages(contentHeight: layout.height, pageHeight: 1056, lines: layout.lines, blocks: layout.blocks)

        let pdf = try await view.pdf(.flow(.letter))

        let pages = try #require(DesignPDF.pages(pdf))
        #expect(pages.count == expected.count && pages.count >= 3)
        #expect(pages.allSatisfy { $0 == CGSize(width: 612, height: 792) }, "Letter")
        // Every cut falls between lines, never through the drawing.
        for slice in expected.dropLast() {
            #expect(!layout.lines.contains { $0.lowerBound < slice.end && $0.upperBound > slice.end })
            #expect(!layout.blocks.contains { $0.lowerBound < slice.end && $0.upperBound > slice.end })
        }
    }

    @Test func documentsMergePageAfterPage() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()
        let one = try await view.pdf(.fixed)

        let merged = try DesignPDF.merge([one, one, one])

        #expect(DesignPDF.pages(merged)?.count == 3)
    }
}

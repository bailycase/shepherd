import CoreGraphics
import Foundation
import PDFKit
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

    /// An imported board never passed board_write's lint, and its page opens outside the sandbox.
    @Test func aStandalonePageKeepsNothingThatRunsEmbedsOrRedirects() async throws {
        let hostile = """
        <!doctype html>
        <html lang="en" onclick="alert('root')" onpointerenter="alert('root')" data-dc-root="stamp">
        <head><meta charset="utf-8"><title>Hostile</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><meta http-equiv="refresh" content="0; url=https://example.com"><base href="https://example.com/"></helmet>
        <div style="width: 200px; height: 100px">
        <a id="bad" href="  JavaScript:alert(1)">Bad</a>
        <a id="good" href="https://example.com/page">Good</a>
        <iframe src="https://example.com"></iframe>
        <object data="x.swf"></object>
        <embed src="x.swf">
        <svg width="10" height="10"><a href="#"><animate attributeName="href" to="javascript:alert(1)"/><rect width="10" height="10"/></a></svg>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":200,"height":100}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
        let harness = try BoardHarness(files: ["Hostile.dc.html": hostile])
        let view = try harness.view("Hostile.dc.html", size: CGSize(width: 200, height: 100))
        try await view.load()

        let page = try await view.staticPage().lowercased()

        #expect(!page.contains("javascript:"))
        #expect(page.hasPrefix("<!doctype html>\n<html lang=\"en\">"), "root language stays; handlers and stamps do not")
        #expect(!page.contains("onclick") && !page.contains("onpointerenter"))
        for tag in ["<script", "<iframe", "<object", "<embed", "<base", "http-equiv", "<animate"] {
            #expect(!page.contains(tag), "\(tag) left")
        }
        #expect(page.contains("href=\"https://example.com/page\""), "an ordinary link stays")
        #expect(page.contains(">bad</a>"), "the link's text stays, without its script")
    }

    @Test func anUnsafeRenderSizeIsRefusedBeforeWebKitNavigates() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html", size: CGSize(width: 1e100, height: 300))
        await #expect(throws: DesignBoardError.self) { try await view.load() }
        #expect(view.navigationsStarted == 0)
        #expect(view.frame.size == .zero && view.webView.frame.size == .zero)
        await #expect(throws: DesignBoardError.self) { try await view.image(scale: 2) }
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

        let pdf = try await view.pdf(.flow(.letter))

        let pages = try #require(DesignPDF.pages(pdf))
        #expect(pages.count >= 3)
        #expect(pages.allSatisfy { $0 == CGSize(width: 612, height: 792) }, "Letter")
        let document = try #require(PDFDocument(data: pdf))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        let labels = try NSRegularExpression(pattern: #"Paragraph \d+\."#)
        let actual = labels.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
        #expect(actual == (0..<60).map { "Paragraph \($0)." }, "each paragraph survives once, in reading order")
    }

    @Test func aDrawingAcrossTheFirstCutMovesIntactToTheSecondPage() async throws {
        // Letter's first printable region ends at 1003 CSS px. This 120px SVG begins
        // at 960, so it belongs wholly on page two, below that page's 53px top gap.
        let board = """
        <html><head><script src="./support.js"></script></head><body style="margin:0;background:white">
        <x-dc><div style="height:960px">Before</div><svg width="100" height="120" style="display:block"><rect width="100" height="120" fill="red"/></svg><div>After</div></x-dc>
        </body></html>
        """
        let harness = try BoardHarness(files: ["Cut.dc.html": board])
        let view = try harness.view("Cut.dc.html", size: CGSize(width: 816, height: 1056))
        try await view.load()
        let pdf = try await view.pdf(.flow(.letter))
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 2)
        let first = try #require(document.page(at: 1))
        let second = try #require(document.page(at: 2))
        func pixel(_ page: CGPDFPage, x: Int, y: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: CGFloat(-x), y: CGFloat(y + 1) - page.getBoxRect(.mediaBox).height)
            context.drawPDFPage(page)
            return Array(bytes.prefix(3))
        }
        #expect(try pixel(first, x: 30, y: 730) == [255, 255, 255])
        #expect(try pixel(second, x: 30, y: 50) == [255, 0, 0])
        #expect(try pixel(second, x: 30, y: 125) == [255, 0, 0])
        #expect(try pixel(second, x: 30, y: 140) == [255, 255, 255])
        let text = try #require(PDFDocument(data: pdf))
        #expect(text.page(at: 0)?.string?.contains("Before") == true)
        #expect(text.page(at: 1)?.string?.contains("After") == true)
    }

    @Test func documentsMergePageAfterPage() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()
        let one = try await view.pdf(.fixed)

        let report = try BoardHarness(files: ["Report.dc.html": Self.flowBoard(paragraphs: 60)])
        let reportView = try report.view("Report.dc.html", size: CGSize(width: 816, height: 1056))
        try await reportView.load()
        let many = try await reportView.pdf(.flow(.letter))
        let inputs = try [one, many].map { try #require(PDFDocument(data: $0)) }
        let expected = inputs.flatMap { doc in (0..<doc.pageCount).map { doc.page(at: $0)?.string } }
        #expect(expected.count > 2)
        #expect(inputs[0].page(at: 0)?.string?.contains("Checkout") == true)
        let merged = try #require(PDFDocument(data: DesignPDF.merge([one, many])))
        #expect((0..<merged.pageCount).map { merged.page(at: $0)?.string } == expected)
    }
}

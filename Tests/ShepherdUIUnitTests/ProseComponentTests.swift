import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

@Suite("Prose components")
@MainActor
struct ProseComponentTests {
    /// A run of styled inline text: its characters and what styles it.
    struct Run: Equatable, CustomStringConvertible {
        var text: String
        var code = false
        var strong = false
        var struck = false
        var link: String?
        var raised = false
        var filled = false

        var description: String { "\(text)\(code ? " code" : "")\(strong ? " strong" : "")\(struck ? " struck" : "")\(link.map { " → \($0)" } ?? "")\(raised ? " raised" : "")\(filled ? " filled" : "")" }
    }

    private func runs(_ text: String) -> [Run] {
        let attributed = NWProseInline.styled(text)
        return attributed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return Run(text: String(attributed[run.range].characters), code: intent.contains(.code), strong: intent.contains(.stronglyEmphasized),
                       struck: run.strikethroughStyle != nil, link: run.link?.absoluteString, raised: (run.baselineOffset ?? 0) > 0,
                       filled: run.backgroundColor != nil)
        }
    }

    private func plain(_ text: String) -> String { String(NWProseInline.styled(text).characters) }

    @Test(arguments: [
        // Inline HTML is never shown raw.
        ("one<br>two<br/>three", "one\ntwo\nthree"),
        ("<b>bold</b> and <i>it</i>", "bold and it"),
        ("<span class=\"x\">kept</span>", "kept"),
        ("<img src=\"https://x.y/a.png\" alt=\"Chart\">", "Chart"),
        // What only looks like a tag is text, and so is code.
        ("Array<Int> and <Element>", "Array<Int> and <Element>"),
        ("`<br>` in code", "<br> in code"),
        // Footnotes: a reference is its number; an escaped one reads as written; code is code.
        ("cited[^2] here", "cited2 here"),
        ("\\[^x] stays", "[^x] stays"),
        ("`[^1]` in code", "[^1] in code"),
        ("![Alt text](shot.png) inline", "Alt text inline"),
        ("~~gone~~", "gone"),
    ])
    func inlineMarkupReadsAsText(markdown: String, text: String) {
        #expect(plain(markdown) == text)
    }

    @Test func htmlTagsStyleTheirText() {
        #expect(runs("<b>bold</b>") == [Run(text: "bold", strong: true)])
        #expect(runs("<s>old</s>") == [Run(text: "old", struck: true)])
        #expect(runs("<code>x</code>") == [Run(text: "x", code: true, filled: true)])
        #expect(runs("<a href=\"https://example.com\">site</a>") == [Run(text: "site", link: "https://example.com")])
        #expect(runs("x<sup>2</sup>") == [Run(text: "x"), Run(text: "2", raised: true)])
    }

    @Test func aKeycapIsFilledAndDropsItsTags() {
        let keys = runs("Press <kbd>⌘K</kbd>")
        #expect(keys.map(\.text).joined() == "Press ⌘K")
        #expect(keys.last == Run(text: "⌘K", filled: true))
    }

    @Test func aFootnoteReferenceIsARaisedNumberAndNoLink() {
        #expect(runs("Tables[^1].") == [Run(text: "Tables"), Run(text: "1", raised: true), Run(text: ".")])
    }

    @Test func strikethroughAndLinksAreStyled() {
        #expect(runs("~~no~~ https://example.com") == [
            Run(text: "no", struck: true), Run(text: " "), Run(text: "https://example.com", link: "https://example.com"),
        ])
    }

    /// An inline image is its alt text: a link only when it is a web image, never fetched.
    @Test func anInlineImageIsItsAltText() {
        #expect(runs("![Chart](https://example.com/c.png)") == [Run(text: "Chart", link: "https://example.com/c.png")])
        #expect(runs("![Local](shot.png)") == [Run(text: "Local")])
    }

    // MARK: Tables

    /// Column widths: natural widths capped at the maximum, hugging content that fits,
    /// growing wrapped columns into spare room, and shrinking toward the minimum when the
    /// table must fit. Outside `fitting` (in a scroll view) columns keep their natural widths.
    @Test(arguments: [
        // Fits: hugs its content.
        (ideal: [100, 80] as [CGFloat], available: 640 as CGFloat?, fitting: true, widths: [100, 80] as [CGFloat]),
        // A long column is capped, then grows into the room left (up to its content).
        (ideal: [200, 1000], available: 640, fitting: true, widths: [200, 440]),
        (ideal: [200, 400], available: 640, fitting: true, widths: [200, 400]),
        // Too wide: each column gives up its share of the overflow, never under the minimum.
        (ideal: [300, 300, 300], available: 600, fitting: true, widths: [200, 200, 200]),
        (ideal: [50, 400, 400], available: 400, fitting: true, widths: [50, 175, 175]),
        // Ideal size (nil): the minimums, so ViewThatFits takes it only when they fit.
        (ideal: [50, 400, 400], available: nil, fitting: true, widths: [50, 100, 100]),
        // In a scroll view: natural widths, whatever the room.
        (ideal: [50, 400, 400], available: 200, fitting: false, widths: [50, 300, 300]),
    ])
    func tableColumnsSizeToContentUpToACap(ideal: [CGFloat], available: CGFloat?, fitting: Bool, widths: [CGFloat]) {
        #expect(NWTableLayout.widths(for: available, ideal: ideal, fitting: fitting, minimum: 100, maximum: 300) == widths)
    }

    /// A column never shrinks under its widest word (an identifier stays whole), up to the cap.
    @Test(arguments: [
        (words: [250, 90] as [CGFloat], available: 400 as CGFloat?, widths: [260, 140] as [CGFloat]),
        (words: [250, 90], available: nil, widths: [250, 100]),
        (words: [900, 900], available: nil, widths: [300, 300]),
    ])
    func aColumnKeepsItsWidestWordWhole(words: [CGFloat], available: CGFloat?, widths: [CGFloat]) {
        #expect(NWTableLayout.widths(for: available, ideal: [300, 300], words: words, fitting: true, minimum: 100, maximum: 300) == widths)
    }

    // MARK: Images

    @Test(arguments: [
        ("https://example.com/a.png", "/work" as String?, "web https://example.com/a.png"),
        ("shot.png", "/work", "file /work/shot.png"),
        ("docs/my%20shot.png", "/work", "file /work/docs/my shot.png"),
        ("/tmp/a.png", "/work", "file /tmp/a.png"),
        ("file:///tmp/a.png", "/work", "file /tmp/a.png"),
        // A remote agent's files are not on this device: never read, only named.
        ("shot.png", nil, "unavailable shot.png"),
        ("/tmp/a.png", nil, "unavailable /tmp/a.png"),
        ("file:///tmp/a.png", nil, "unavailable /tmp/a.png"),
        ("data:image/png;base64,AAAA", "/work", "unavailable data:image/png;base64,AAAA"),
    ])
    func imageSourcesResolveOnlyWhereTheFilesAre(source: String, root: String?, resolved: String) {
        let value = NWProseImageSource(source, root: root.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let text = switch value {
        case .file(let url): "file \(url.path)"
        case .web(let url): "web \(url.absoluteString)"
        case .unavailable(let text): "unavailable \(text)"
        }
        #expect(text == resolved)
    }

    // MARK: Fences and lists

    @Test(arguments: [
        (nil as String?, "code", false),
        ("swift", "swift", false),
        ("mermaid", "mermaid · diagram source", true),
        ("math", "math · math source", true),
        ("LaTeX", "LaTeX · math source", true),
    ])
    func diagramAndMathFencesSayTheyAreSource(language: String?, label: String, glyph: Bool) {
        let kind = NWFenceKind(language)
        #expect(kind.label == label)
        #expect((kind.glyph != nil) == glyph)
    }

    @Test func bulletsChangeWithDepth() {
        #expect((0..<4).map { NWProseBlocks<EmptyView>.bullet(depth: $0) } == ["•", "◦", "▪\u{FE0E}", "•"])
    }
}

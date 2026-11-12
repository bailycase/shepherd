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
        let attributed = SHProseInline.styled(text)
        return attributed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return Run(text: String(attributed[run.range].characters), code: intent.contains(.code), strong: intent.contains(.stronglyEmphasized),
                       struck: run.strikethroughStyle != nil, link: run.link?.absoluteString, raised: (run.baselineOffset ?? 0) > 0,
                       filled: run.backgroundColor != nil)
        }
    }

    private func plain(_ text: String) -> String { String(SHProseInline.styled(text).characters) }

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

    // MARK: Project task references (ProjectLead-Question)

    private let known = "shepherd-project-task://p/t1"
    private var table: SHProseTaskLinks { .init(links: [known: .init(title: "Library API draft", tone: .attention)]) }

    /// What the paragraph shows, with each chip's room run (a hair space) and its non-breaking title.
    private func chipText(_ markdown: String) -> String {
        let attributed = SHProseInline.styled(markdown)
        guard SHProseTaskLinks.hasReference(attributed) else { return String(attributed.characters) }
        // The runs the renderer builds are Text values; their words are what the layout holds.
        var words = ""
        for run in attributed.runs {
            let piece = AttributedString(attributed[run.range])
            if let url = run.link, url.scheme == SHProseTaskLinks.scheme, let link = table.links[url.absoluteString] {
                words += "\u{200A}" + link.title.replacingOccurrences(of: " ", with: "\u{00A0}")
            } else {
                words += String(SHProseTaskLinks.inert(piece).characters)
            }
        }
        return words
    }

    @Test func aResolvingReferenceShowsTheOwnersCurrentTitleNotTheModelsWords() {
        #expect(chipText("See [whatever the model wrote](\(known)) now.") == "See \u{200A}Library\u{00A0}API\u{00A0}draft now.")
    }

    @Test(arguments: [
        "[gone](shepherd-project-task://p/missing)",
        "[other project](shepherd-project-task://q/t1)",
        "[bad](shepherd-project-task://)",
    ])
    func aStaleCrossProjectOrMalformedReferenceIsPlainWordsWithNoLink(markdown: String) {
        let attributed = SHProseInline.styled(markdown)
        let inert = SHProseTaskLinks.inert(attributed)
        #expect(!SHProseTaskLinks.hasReference(inert), "no link survives")
        #expect(inert.runs.allSatisfy { $0.link == nil && $0.foregroundColor == nil })
        #expect(String(inert.characters) == String(attributed.characters), "the words are as written")
        #expect(table.links[attributed.runs.first?.link?.absoluteString ?? ""] == nil)
    }

    @Test func aReferenceStillBeingWrittenIsPlainTextUntilItCloses() {
        for partial in ["[Partner API", "[Library API draft](", "[Library API draft](shepherd-project-task://p/t", "[Library API draft](shepherd-project-task://p/t1"] {
            #expect(!SHProseTaskLinks.hasReference(SHProseInline.styled(partial)), "\(partial) is not a link")
        }
        #expect(SHProseTaskLinks.hasReference(SHProseInline.styled("[Library API draft](\(known))")))
    }

    @Test func aLongTitleStaysOneNonBreakingRunAndOrdinaryLinksAreUntouched() {
        let long = String(repeating: "Very long task name ", count: 12)
        let link = SHProseTaskLinks(links: [known: .init(title: long, tone: .running)])
        #expect(link.links[known]?.title == long)
        #expect(!SHProseTaskLinks.hasReference(SHProseInline.styled("[site](https://example.com)")), "an ordinary link is not a task reference")
        #expect(runs("[site](https://example.com)") == [Run(text: "site", link: "https://example.com")])
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
    typealias ColumnCase = (ideal: [CGFloat], available: CGFloat?, fitting: Bool, widths: [CGFloat])

    // Typed up front: inferring this table's tuples timed out the type checker on CI.
    nonisolated static let columnCases: [ColumnCase] = [
        // Fits: hugs its content.
        (ideal: [100, 80], available: 640, fitting: true, widths: [100, 80]),
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
    ]

    @Test(arguments: columnCases)
    func tableColumnsSizeToContentUpToACap(ideal: [CGFloat], available: CGFloat?, fitting: Bool, widths: [CGFloat]) {
        #expect(SHTableLayout.widths(for: available, ideal: ideal, fitting: fitting, minimum: 100, maximum: 300) == widths)
    }

    /// A column never shrinks under its widest word (an identifier stays whole), up to the cap.
    nonisolated static let wordCases: [(words: [CGFloat], available: CGFloat?, widths: [CGFloat])] = [
        (words: [250, 90], available: 400, widths: [260, 140]),
        (words: [250, 90], available: nil, widths: [250, 100]),
        (words: [900, 900], available: nil, widths: [300, 300]),
    ]

    @Test(arguments: wordCases)
    func aColumnKeepsItsWidestWordWhole(words: [CGFloat], available: CGFloat?, widths: [CGFloat]) {
        #expect(SHTableLayout.widths(for: available, ideal: [300, 300], words: words, fitting: true, minimum: 100, maximum: 300) == widths)
    }

    /// A table's layout is built again for every width, hover and scroll back into view; its
    /// words are measured when a cell or the type changes, and not otherwise.
    @Test func tableWordsAreMeasuredOncePerTable() {
        func table(_ cells: [[String]]) -> SHProseTable {
            SHProseTable(alignments: [.leading, .trailing], header: ["Name", "Notes"],
                         rows: cells.map { $0.map { AttributedString($0) } }, markdown: "")
        }
        let words = SHTableWords()
        let rows = [["identifier_one", "a few plain words"], ["two", "internationalization"]]
        let first = words.columns(of: table(rows), size: .regular, scale: 1, dynamicType: .large)
        #expect(first.count == 2 && first[1] > first[0], "\(first)")
        #expect(words.measured == 6, "each of the six cells once")

        for _ in 0..<5 { #expect(words.columns(of: table(rows), size: .regular, scale: 1, dynamicType: .large) == first) }
        #expect(words.measured == 6, "an equal table is the same table")

        let edited = [rows[0], ["two", "another"]]
        _ = words.columns(of: table(edited), size: .regular, scale: 1, dynamicType: .large)
        #expect(words.measured == 7, "one changed cell")
        _ = words.columns(of: table(rows), size: .small, scale: 1, dynamicType: .large)
        #expect(words.measured == 13, "a new prose size")
        _ = words.columns(of: table(rows), size: .regular, scale: 1.25, dynamicType: .large)
        #expect(words.measured == 19, "a new text scale")
        _ = words.columns(of: table(rows), size: .regular, scale: 1, dynamicType: .xxxLarge)
        #expect(words.measured == 25, "a new dynamic type size")
    }

    @Test(arguments: [
        ("temporal/PLAN.md", "/work" as String?, "file:///work/temporal/PLAN.md" as String?),
        ("./temporal/PLAN.md", "/work", "file:///work/temporal/PLAN.md"),
        ("../PLAN.md", "/work/tree", "file:///work/PLAN.md"),
        ("docs/my%20plan.md#notes", "/work", "file:///work/docs/my%20plan.md"),
        ("/tmp/PLAN.md", "/work", "file:///tmp/PLAN.md"),
        ("file:///tmp/PLAN.md", "/work", "file:///tmp/PLAN.md"),
        ("temporal/PLAN.md", nil, nil),
        ("/tmp/PLAN.md", nil, nil),
        ("file:///tmp/PLAN.md", nil, nil),
        ("#notes", "/work", nil),
        ("https://example.com/plan#notes", nil, "https://example.com/plan#notes"),
        ("shepherd-project-task://project/task", "/work", "shepherd-project-task://project/task"),
    ])
    func proseLinksResolveAgainstTheAgentsDirectory(source: String, root: String?, expected: String?) throws {
        let markdown = SHProseInline.styled("[plan](\(source))")
        let link = try #require(markdown.runs.first?.link)
        let destination = SHProseLink.destination(link, root: root.map { URL(fileURLWithPath: $0, isDirectory: true) })
        #expect(destination?.absoluteString == expected)
    }

    /// The router resolves a link as above and hands the result to the opener it was given; with no folder a relative path
    /// opens nothing, and with no opener nothing opens. Its action is made once and follows the folder and opener it is
    /// given later, which is how a prose view that redraws keeps one action.
    @Test func theLinkRouterResolvesThenHandsToTheOpener() throws {
        let relative = try #require(URL(string: "temporal/PLAN.md"))
        let web = try #require(URL(string: "https://example.com/plan"))
        let router = SHProseLinkRouter()
        let action = router.action
        var first: [URL] = []
        var second: [URL] = []

        router.root = URL(fileURLWithPath: "/work", isDirectory: true)
        action(relative)
        #expect(first.isEmpty, "no opener yet")

        router.outer = OpenURLAction { first.append($0); return .handled }
        action(relative)
        router.open(web)
        #expect(first.map(\.absoluteString) == ["file:///work/temporal/PLAN.md", "https://example.com/plan"])

        router.outer = OpenURLAction { second.append($0); return .handled }
        router.root = URL(fileURLWithPath: "/other", isDirectory: true)
        action(relative)
        #expect(second.map(\.absoluteString) == ["file:///other/temporal/PLAN.md"])

        router.root = nil
        action(relative)
        action(web)
        #expect(second.map(\.absoluteString) == ["file:///other/temporal/PLAN.md", "https://example.com/plan"],
                "a remote agent's path opens no same-named file here")
        #expect(first.count == 2)
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
        let value = SHProseImageSource(source, root: root.map { URL(fileURLWithPath: $0, isDirectory: true) })
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
        let kind = SHFenceKind(language)
        #expect(kind.label == label)
        #expect((kind.glyph != nil) == glyph)
    }

    @Test func bulletsChangeWithDepth() {
        #expect((0..<4).map { SHProseWords.bullet(depth: $0) } == ["•", "◦", "▪\u{FE0E}", "•"])
    }

    // MARK: Block views

    /// The open fence is the last one of the chunk, wherever it sits. The chunk names the part that holds it, and the path
    /// below that part's own block: empty for a top-level fence, else an index per level (a quote's or a disclosure's block,
    /// a list's item and then its block), so a block view needs nothing of the levels above it.
    @Test(arguments: [
        ("a top-level fence", [proseTestPart(0, .paragraph("Intro")), proseTestPart(1, proseTestFence("open"))], 1, []),
        ("a fence after the quote that holds one", [proseTestPart(0, .quote([proseTestFence("closed")])), proseTestPart(1, proseTestFence("open"))], 1, []),
        ("a fence in a quote", [proseTestPart(0, .paragraph("Intro")), proseTestPart(1, .quote([.paragraph("Said"), proseTestFence("open")]))], 1, [1]),
        ("a fence in a list item", [proseTestPart(0, .list(ordered: false, start: 1, items: [
            SHProseListItem(text: "one"), SHProseListItem(text: "two", children: [.paragraph("Under"), proseTestFence("open")]),
        ]))], 0, [1, 1]),
        ("a fence in a disclosure", [proseTestPart(0, .details(summary: "More", blocks: [proseTestFence("open")])), proseTestPart(1, .paragraph("After"))], 0, [0]),
        ("a fence in a list in a quote", [proseTestPart(0, .quote([.list(ordered: true, start: 1, items: [
            SHProseListItem(text: "", children: [proseTestFence("open")]),
        ])]))], 0, [0, 0, 0]),
    ] as [(String, [SHProsePart], Int, [Int])])
    func theOpenFenceNamesItsPartAndTheWayDownInsideIt(_: String, parts: [SHProsePart], holder: Int, path: [Int]) {
        let chunk = SHProseChunk<SHCodeBlock>(parts, writingFence: true)
        #expect(chunk.writing?.part == parts[holder].id)
        #expect(chunk.writing?.path == path)
        for (index, part) in parts.enumerated() {
            #expect(chunk.writing(in: part) == (index == holder ? path : nil), "part \(index)")
        }
        #expect(SHProseChunk<SHCodeBlock>(parts, writingFence: false).writing == nil, "a finished reply writes none")
    }

    @Test func aChunkWithoutFencesWritesNone() {
        let parts = [proseTestPart(0, .paragraph("Intro")), proseTestPart(1, .quote([.paragraph("Said")]))]
        #expect(SHProseChunk<SHCodeBlock>(parts, writingFence: true).writing == nil)
    }

    /// Below the part, each block gets only what is left of the path: the block whose index leads it, with that index taken off,
    /// and the fence itself sees an empty path.
    @Test func theWritingPathIsHandedDownOneLevelAtATime() {
        typealias Blocks = SHProseBlocks<SHCodeBlock>
        let path = [1, 0, 2]
        #expect(Blocks.writing(path, under: 0) == nil)
        #expect(Blocks.writing(path, under: 1) == [0, 2])
        #expect(Blocks.writing(path, under: 2) == nil)
        #expect(Blocks.writing([0, 2], under: 0) == [2])
        #expect(Blocks.writing([2], under: 2) == [])
        #expect(Blocks.writing(nil, under: 0) == nil)
    }

    @Test func aChunkIsEqualWhenItsPartsAndItsOpenFenceAre() {
        let parts = [proseTestPart(0, .paragraph("Intro")), proseTestPart(1, proseTestFence("open"))]
        let chunk = SHProseChunk<SHCodeBlock>(parts, writingFence: true)
        #expect(chunk == SHProseChunk<SHCodeBlock>(parts, writingFence: true))
        #expect(chunk != SHProseChunk<SHCodeBlock>(parts, writingFence: false), "the fence is finished")
        #expect(chunk != SHProseChunk<SHCodeBlock>(parts, writing: (parts[0].id, [])), "another part holds the fence")
        #expect(chunk != SHProseChunk<SHCodeBlock>(parts, writing: (parts[1].id, [0])), "another path inside it")
        #expect(chunk != SHProseChunk<SHCodeBlock>([parts[0], proseTestPart(1, proseTestFence("opened"))], writingFence: true))
        #expect(chunk != SHProseChunk<SHCodeBlock>([parts[0], proseTestPart(2, proseTestFence("open"))], writingFence: true), "another id")
    }

    /// A block's view is drawn again when anything it draws differs: its words and their styles, the fence it writes, whether it
    /// sits nested, how deep in lists, and in which voice. A pull that leaves all of them as they were draws nothing.
    @Test func aBlockViewIsEqualOnlyWhenEverythingItDrawsIs() {
        typealias BlockView = SHProseBlockView<SHCodeBlock>
        let bold = AttributeContainer().inlinePresentationIntent(.stronglyEmphasized)
        let base = BlockView(block: .paragraph(AttributedString("Same words")))
        #expect(base == BlockView(block: .paragraph(AttributedString("Same words"))))
        #expect(base != BlockView(block: .paragraph(AttributedString("Same words, longer"))), "its words")
        #expect(base != BlockView(block: .paragraph(AttributedString("Same words", attributes: bold))), "their styles")
        #expect(base != BlockView(block: .heading(level: 2, text: AttributedString("Same words"))), "its kind")
        #expect(base != BlockView(block: base.block, writing: []), "a fence being written")
        #expect(base != BlockView(block: base.block, nested: true))
        #expect(base != BlockView(block: base.block, depth: 1))
        #expect(base != BlockView(block: base.block, voice: .quoted))
        #expect(base != BlockView(block: base.block, voice: .thinking))

        let fence = BlockView(block: proseTestFence("let a = 1"), writing: [])
        #expect(fence == BlockView(block: proseTestFence("let a = 1"), writing: []))
        #expect(fence != BlockView(block: proseTestFence("let a = 1"), writing: nil))
        #expect(fence != BlockView(block: proseTestFence("let a = 12"), writing: []))
        #expect(fence != BlockView(block: .code("let a = 1", language: "go"), writing: []))
        #expect(BlockView(block: .rule) == BlockView(block: .rule))
    }

    @Test func aListItemViewIsEqualOnlyWhenEverythingItDrawsIs() {
        typealias Item = SHProseListItemView<SHCodeBlock>
        let item = SHProseListItem(text: "one", task: .open, children: [.paragraph("Under")])
        let base = Item(item: item, ordered: true, number: 1)
        #expect(base == Item(item: item, ordered: true, number: 1))
        #expect(base != Item(item: SHProseListItem(text: "one", task: .done, children: [.paragraph("Under")]), ordered: true, number: 1))
        #expect(base != Item(item: SHProseListItem(text: "one", task: .open, children: [.paragraph("Under it")]), ordered: true, number: 1))
        #expect(base != Item(item: item, ordered: false, number: 1))
        #expect(base != Item(item: item, ordered: true, number: 2), "its number")
        #expect(base != Item(item: item, ordered: true, number: 1, writing: [0]))
        #expect(base != Item(item: item, ordered: true, number: 1, depth: 1))
        #expect(base != Item(item: item, ordered: true, number: 1, voice: .thinking))
    }
}

private func proseTestPart(_ block: Int, _ value: SHProseBlock, stretch: Int = 0) -> SHProsePart {
    SHProsePart(id: .init(block: block, stretch: stretch), block: value)
}

private func proseTestFence(_ code: String) -> SHProseBlock { .code(code, language: "swift") }

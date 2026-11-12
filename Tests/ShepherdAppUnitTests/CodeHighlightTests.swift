import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Behaviors use the Go and Python grammars: the Swift grammar's query compile alone costs
/// ~0.3s, and nothing here depends on the language.
@Suite("Code highlighting")
@MainActor
struct CodeHighlightTests {
    private static func solid(_ hex: String) -> Color { Color(light: hex, dark: hex) }

    private let style = CodeHighlight.Style(
        comment: Self.solid("#565758"), string: Self.solid("#A1C592"), number: Self.solid("#CEB370"),
        keyword: Self.solid("#8892B5"), type: Self.solid("#A38FB5"), function: Self.solid("#8FB3AD")
    )

    private func color(of fragment: String, in line: AttributedString) -> Color? {
        line.runs.first { String(line[$0.range].characters).contains(fragment) }?.foregroundColor
    }

    @Test(arguments: [
        ("Swift", "fence.swift"), ("py", "fence.py"), ("golang", "fence.go"), ("rs", "fence.rs"),
        ("jsx", "fence.js"), ("ts", "fence.ts"), ("tsx", "fence.tsx"), ("c++", "fence.cpp"),
        ("zsh", "fence.sh"), ("console", "fence.sh"), ("rb", "fence.rb"), ("jsonc", "fence.json"),
        ("brainfuck", nil),
    ] as [(String, String?)])
    func fenceLanguagesPickAGrammar(language: String, path: String?) {
        #expect(CodeHighlight.path(forFenceLanguage: language) == path)
    }

    @Test func aFenceWithoutALanguageHasNoGrammar() {
        #expect(CodeHighlight.path(forFenceLanguage: nil) == nil)
    }

    @Test func keywordsStringsAndCommentsTakeTheirRoles() throws {
        let line = try #require(CodeHighlight.highlightLines([#"var value = "hello" // done"#], path: "main.go", style: style).first)
        #expect(color(of: "var", in: line) == style.keyword)
        #expect(color(of: "hello", in: line) == style.string)
        #expect(color(of: "// done", in: line) == style.comment)
    }

    @Test func pythonHashCommentsAreComments() throws {
        let line = try #require(CodeHighlight.highlightLines(["value = 42  # count"], path: "script.py", style: style).first)
        #expect(color(of: "# count", in: line) == style.comment)
    }

    /// Lines are highlighted as one document, so a block comment spans the line break.
    @Test func blockCommentsContinueAcrossLines() {
        let lines = CodeHighlight.highlightLines(["var value = 1 /* start", "continuation */"], path: "main.go", style: style)
        #expect(lines.count == 2)
        #expect(color(of: "/* start", in: lines[0]) == style.comment)
        #expect(color(of: "continuation */", in: lines[1]) == style.comment)
    }

    /// Tree-sitter reports UTF-16 ranges; astral characters before a capture must not shift colors.
    @Test func unicodeBeforeACaptureKeepsRangesAligned() throws {
        let line = try #require(CodeHighlight.highlightLines([#"x = "🐑🐑" if ok else 'hello'  # done"#], path: "a.py", style: style).first)
        #expect(color(of: "if", in: line) == style.keyword)
        #expect(color(of: "hello", in: line) == style.string)
        #expect(color(of: "# done", in: line) == style.comment)
    }

    @Test func unknownExtensionsStayUnstyledButKeepTheirText() throws {
        let source = #"let value = "hello""#
        let line = try #require(CodeHighlight.highlightLines([source], path: "config.xyz", style: style).first)
        #expect(line.runs.allSatisfy { $0.foregroundColor == nil })
        #expect(String(line.characters) == source)
    }

    @Test(arguments: [("main.go", true), ("App.swift", true), ("script.py", true), ("notes.txt", false), ("Makefile", false)])
    func onlyGrammarsWeShipAreSupported(path: String, supported: Bool) {
        #expect(CodeHighlight.supports(path: path) == supported)
    }

    /// A thread's fenced block renders off the main actor as one colored string, line breaks
    /// kept; a language without a grammar stays plain.
    @Test func aFencedBlockRendersOffTheMainActor() async throws {
        let style = style
        let key = CodeHighlightCache.Key(code: "var value = 1\n// done", language: "go")
        let block = try #require(await Task.detached { CodeHighlightCache.render(key, style: style) }.value)
        #expect(String(block.characters) == key.code)
        #expect(color(of: "// done", in: block) == style.comment)
        #expect(CodeHighlightCache.render(CodeHighlightCache.Key(code: "+++", language: "brainfuck"), style: style) == nil)
    }

    /// A block draws only colors of its own code. While a streaming block grows, its last colors
    /// stay and the new text follows plain; changed or other code draws plain until colored.
    @Test(arguments: [
        ("var a = 1", "go", "var a = 1", "var a = 1"),
        ("var a = 1\n// done", "go", "var a = 1", "var a = 1\n// done"),
        ("var b = 2", "go", "var a = 1", nil),
        ("var a = 1\n// done", "python", "var a = 1", nil),
    ] as [(String, String, String, String?)])
    func aBlockDrawsOnlyColorsOfItsOwnCode(code: String, language: String, lastCode: String, drawn: String?) throws {
        let last = CodeHighlightCache.Key(code: lastCode, language: "go")
        let lastColors = try #require(CodeHighlightCache.render(last, style: style))
        let key = CodeHighlightCache.Key(code: code, language: language)
        let colors = CodeHighlightCache.colors(for: key, last: CodeHighlightCache.Rendered(key: last, value: lastColors), cached: nil)
        #expect(colors.map { String($0.characters) } == drawn)
        if let colors { #expect(color(of: "var", in: colors) == style.keyword) }
    }

    /// Colors cached for the block's current code win over the last ones it rendered, and a
    /// fence's surrounding newlines are not part of its key.
    @Test func cachedColorsForTheCurrentCodeWin() throws {
        let key = CodeHighlightCache.Key(fence: "\nvar b = 2\n", language: "go")
        #expect(key.code == "var b = 2")
        let cached = try #require(CodeHighlightCache.render(key, style: style))
        let last = CodeHighlightCache.Rendered(key: CodeHighlightCache.Key(code: "var", language: "go"), value: AttributedString("var"))
        #expect(CodeHighlightCache.colors(for: key, last: last, cached: cached) == cached)
        #expect(CodeHighlightCache.colors(for: key, last: nil, cached: nil) == nil)
    }

    /// The review and the thread's code blocks both highlight off the main thread: concurrent
    /// calls share compiled grammars and must agree.
    @Test func concurrentCallsGiveTheSameColors() async {
        let source = [#"var value = "hello" // done"#, "func f() int { return 42 }"]
        let style = style
        let expected = CodeHighlight.highlightLines(source, path: "main.go", style: style)
        let results = await withTaskGroup(of: [AttributedString].self) { group in
            for _ in 0..<8 {
                group.addTask { CodeHighlight.highlightLines(source, path: "main.go", style: style) }
            }
            var results: [[AttributedString]] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 8 && results.allSatisfy { $0 == expected })
    }

    @Test func outputHasOneLinePerInputLine() {
        #expect(CodeHighlight.highlightLines([], path: "main.go", style: style).isEmpty)
        #expect(CodeHighlight.highlightLines(["a", "", "b"], path: "main.go", style: style).map { String($0.characters) } == ["a", "", "b"])
    }

    // MARK: A block a reply is writing

    private typealias Throttle = CodeHighlightThrottle
    private static let start = ContinuousClock.now

    /// The policy for a fence a streaming reply is writing, and for a finished one.
    @Test(arguments: [
        // Its first complete line colors at once.
        ("a\nb", true, nil, 0, Throttle.Decision.render(lines: 1)),
        // Text added within the last line waits for the line to end, however long ago.
        ("a\nb and more", true, 1, 5_000, .keep),
        // A line boundary past the interval colors every complete line.
        ("a\nb\nc\nd", true, 1, 300, .render(lines: 3)),
        // A line boundary inside the interval waits out the rest of it.
        ("a\nb\nc", true, 1, 100, .wait(.milliseconds(150))),
        // A finished block (the fence closed, or the reply done) colors all of it, now.
        ("a\nb\nc", false, 2, 10, .render(lines: nil)),
        ("a", false, nil, 0, .render(lines: nil)),
    ] as [(String, Bool, Int?, Int, CodeHighlightThrottle.Decision)])
    func aBlockBeingWrittenIsColoredAtLineBoundariesAndAtMostEvery250ms(code: String, writing: Bool, lastLines: Int?, sinceMS: Int,
                                                                         expected: CodeHighlightThrottle.Decision) {
        let last = lastLines.map { Throttle.Render(at: Self.start, lines: $0) }
        let decision = Throttle.decide(code: code, writing: writing, last: last, now: Self.start + .milliseconds(sinceMS))
        #expect(decision == expected)
    }

    /// The colors drawn between renders: the last render's for the lines it colored, the new
    /// text plain after them.
    @Test func aBlockKeepsItsLastColorsWithTheNewTextPlainAfterThem() throws {
        let full = CodeHighlightCache.Key(code: "var a = 1\nvar b = 2\nvar c", language: "go")
        let prefix = CodeHighlightCache.Key(code: "var a = 1\nvar b = 2", language: "go")
        let colored = try #require(CodeHighlightCache.render(prefix, style: style))

        let drawn = try #require(CodeHighlightCache.colors(for: full, last: CodeHighlightCache.Rendered(key: prefix, value: colored), cached: nil))

        #expect(String(drawn.characters) == full.code)
        #expect(drawn.runs.contains { $0.foregroundColor == style.keyword })
    }

    /// A render a newer one superseded is dropped: cancelled, it colors nothing.
    @Test func aCancelledRenderReturnsNothing() {
        let key = CodeHighlightCache.Key(code: "var a = 1\nvar b = 2", language: "go")
        #expect(CodeHighlightCache.render(key, style: style, isCancelled: { true }) == nil)
        #expect(CodeHighlightCache.render(key, style: style, isCancelled: { false }) != nil)
    }

    /// A fence is drawn again only when its code, language or writing flag changes: what it renders (colors, throttle) is
    /// state, never an input.
    @Test func aFenceIsComparedByItsCodeLanguageAndWritingFlag() {
        let fence = HighlightedCodeBlock(code: "var a = 1", language: "go", writing: false)
        #expect(fence == HighlightedCodeBlock(code: "var a = 1", language: "go", writing: false))
        #expect(fence != HighlightedCodeBlock(code: "var a = 1\n", language: "go", writing: false))
        #expect(fence != HighlightedCodeBlock(code: "var a = 1", language: "python", writing: false))
        #expect(fence != HighlightedCodeBlock(code: "var a = 1", language: "go", writing: true))
        #expect(SHCodeBlock("var a = 1", language: "go") == SHCodeBlock("var a = 1", language: "go"))
        #expect(SHCodeBlock("var a = 1", language: "go") != SHCodeBlock("var a = 1", language: "go", highlighted: AttributedString("var a = 1")))
    }

    // MARK: What the cache keeps

    private func colored(_ key: CodeHighlightCache.Key) throws -> AttributedString {
        try #require(CodeHighlightCache.render(key, style: style))
    }

    /// A fence's code is drawn without its leading and trailing newlines; the rest is left as it is.
    @Test(arguments: [
        ("\nvar a = 1\n", "var a = 1"), ("\r\n\nvar a = 1\r\n", "var a = 1"), ("var a = 1\n\nvar b = 2", "var a = 1\n\nvar b = 2"),
        ("  var a = 1  ", "  var a = 1  "), ("", ""), ("\n", ""), ("var a = \"\u{2028}\"\u{2028}", "var a = \"\u{2028}\""),
    ] as [(String, String)])
    func aFencesCodeIsTrimmedOfItsSurroundingNewlinesOnly(fence: String, code: String) {
        #expect(CodeHighlightCache.Key(fence: fence, language: "go").code == code)
    }

    /// The cache is limited by what its entries hold, not by how many there are: a fence's code and its colored runs.
    @Test func anEntryCostsItsCodeAndItsRuns() {
        let key = CodeHighlightCache.Key(code: "ab\ncd", language: "go")
        var keyword = AttributedString("cd")
        keyword.foregroundColor = Self.solid("#8892B5")
        let value = AttributedString("ab\n") + keyword
        #expect(value.runs.count == 2)
        #expect(CodeHighlightCache.cost(of: key, value) == 5 * 2 + 2 * 384)
        #expect(CodeHighlightCache.cost(of: CodeHighlightCache.Key(code: "🐑", language: nil), AttributedString("🐑")) == 4 * 2 + 384)
    }

    /// A render larger than the whole budget is not stored: NSCache would evict the others to make room for it.
    @Test func anEntryLargerThanTheBudgetIsNotStored() {
        let big = CodeHighlightCache.Key(code: String(repeating: "x", count: CodeHighlightCache.costLimit / 2 + 1), language: "go")
        let small = CodeHighlightCache.Key(code: "var small1 = 1", language: "go")
        CodeHighlightCache.store(AttributedString("var small1 = 1"), for: small)

        CodeHighlightCache.store(AttributedString(big.code), for: big)

        #expect(CodeHighlightCache.cached(big) == nil)
        #expect(CodeHighlightCache.cached(small) != nil)
        #expect(CodeHighlightCache.costLimit == 16 * 1024 * 1024)
    }
}

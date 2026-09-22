import Testing
import SwiftUI
import ShepherdDesign
@testable import ShepherdApp

@MainActor
@Suite("Code highlighting")
struct CodeHighlightTests {
    private let style = CodeHighlight.Style(
        comment: Color(hex: "#565758"), string: Color(hex: "#A1C592"), number: Color(hex: "#CEB370"),
        keyword: Color(hex: "#8892B5"), type: Color(hex: "#A38FB5"), function: Color(hex: "#8FB3AD")
    )

    @Test func fenceLanguagesPickAGrammar() {
        #expect(CodeHighlight.path(forFenceLanguage: "Swift") == "fence.swift")
        #expect(CodeHighlight.path(forFenceLanguage: "sh") == "fence.sh")
        #expect(CodeHighlight.path(forFenceLanguage: "brainfuck") == nil)
        #expect(CodeHighlight.path(forFenceLanguage: nil) == nil)
    }

    private func runs(_ attributed: AttributedString) -> [(String, Color?)] {
        attributed.runs.map { run in
            (String(attributed[run.range].characters), run.foregroundColor)
        }
    }

    private func contains(_ text: String, colored color: Color, in attributed: AttributedString) -> Bool {
        runs(attributed).contains { fragment, foregroundColor in
            fragment.contains(text) && foregroundColor == color
        }
    }

    @Test func swiftKeywordStringAndComment() {
        let highlighted = CodeHighlight.highlightLines(
            [#"let value = "hello" // done"#],
            path: "Foo.swift",
            style: style
        )
        #expect(highlighted.count == 1)
        #expect(contains("let", colored: style.keyword, in: highlighted[0]))
        #expect(contains("hello", colored: style.string, in: highlighted[0]))
        #expect(contains("// done", colored: style.comment, in: highlighted[0]))
    }

    @Test func pythonHashComment() {
        let highlighted = CodeHighlight.highlightLines(
            ["value = 42  # count"],
            path: "script.py",
            style: style
        )
        #expect(highlighted.count == 1)
        #expect(contains("# count", colored: style.comment, in: highlighted[0]))
    }

    @Test func swiftBlockCommentContinuesAcrossLines() {
        let highlighted = CodeHighlight.highlightLines(
            ["let value = 1 /* start", "continuation */"],
            path: "Foo.swift",
            style: style
        )
        #expect(highlighted.count == 2)
        #expect(contains("/* start", colored: style.comment, in: highlighted[0]))
        #expect(contains("continuation */", colored: style.comment, in: highlighted[1]))
    }

    @Test func unicodeBeforeCaptureUsesUTF16Ranges() {
        let highlighted = CodeHighlight.highlightLines(
            ["let 🐑 = \"hello\""],
            path: "Foo.swift",
            style: style
        )
        #expect(highlighted.count == 1)
        #expect(contains("let", colored: style.keyword, in: highlighted[0]))
        #expect(contains("hello", colored: style.string, in: highlighted[0]))
    }

    @Test func unknownExtensionIsUnstyled() {
        let highlighted = CodeHighlight.highlightLines(
            [#"let value = "hello""#],
            path: "config.xyz",
            style: style
        )
        #expect(highlighted.count == 1)
        #expect(runs(highlighted[0]).allSatisfy { $0.1 == nil })
    }

    @Test func emptyInputIsEmpty() {
        #expect(CodeHighlight.highlightLines([], path: "Foo.swift", style: style).isEmpty)
    }
}

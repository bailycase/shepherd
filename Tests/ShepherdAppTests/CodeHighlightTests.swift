import Testing
import SwiftUI
@testable import ShepherdApp

@MainActor
@Suite("Code highlighting")
struct CodeHighlightTests {
    private let style = CodeHighlight.Style(palette: [
        "#1A1B1D", "#B87D6E", "#A1C592", "#CEB370",
        "#8892B5", "#A38FB5", "#8FB3AD", "#CDD0D7",
        "#565758", "#C99284", "#B3D1A4", "#DCC48A",
        "#9FA9C9", "#B8A6C9", "#A4C7C1", "#EDEDED",
    ])

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

import Foundation
import Testing
@testable import ShepherdRemote

/// Settings ▸ Instructions' text rules: sizes, diffs, the lines a draft changed, what a save
/// changed in words, and the editor's light Markdown.
@Suite("Instructions text")
struct InstructionsTextTests {
    @Test(arguments: [
        ("", "empty"),
        ("  \n", "empty"),
        ("ok", "~1 token"),
        (String(repeating: "x", count: 160), "~40 tokens"),
        (String(repeating: "x", count: 360), "~90 tokens"),
        (String(repeating: "x", count: 2_560), "~640 tokens"),
        (String(repeating: "x", count: 2_590), "~650 tokens"),
    ])
    func aFileSaysRoughlyHowManyTokensItCosts(text: String, note: String) {
        #expect(InstructionsText.sizeNote(text) == note)
    }

    @Test func aFinalNewlineEndsTheLastLine() {
        #expect(InstructionsText.lines("") == [])
        #expect(InstructionsText.lines("a") == ["a"])
        #expect(InstructionsText.lines("a\nb\n") == ["a", "b"])
        #expect(InstructionsText.lines("a\n\n") == ["a", ""])
    }

    @Test func aChangedLineReadsAsRemovedThenAdded() {
        let diff = InstructionsText.diff(from: "a\nb\nc\n", to: "a\nx\nc\n")
        #expect(diff == [
            InstructionsDiffLine(kind: .context, text: "a", number: 1),
            InstructionsDiffLine(kind: .removed, text: "b", number: 2),
            InstructionsDiffLine(kind: .added, text: "x", number: 2),
            InstructionsDiffLine(kind: .context, text: "c", number: 3),
        ])
    }

    @Test func linesOnlyAddedOrOnlyRemovedKeepTheirNumbers() {
        #expect(InstructionsText.diff(from: "a\n", to: "a\nb\nc\n").filter { $0.kind == .added }.map(\.number) == [2, 3])
        #expect(InstructionsText.diff(from: "a\nb\nc\n", to: "c\n").filter { $0.kind == .removed }.map(\.text) == ["a", "b"])
        #expect(InstructionsText.diff(from: "", to: "").isEmpty)
    }

    @Test func theEditorTintsOnlyTheDraftsNewOrChangedLines() {
        #expect(InstructionsText.changedLines(saved: "a\nb\nc\n", draft: "a\nB\nc\nd\n") == [1, 3])
        #expect(InstructionsText.changedLines(saved: "a\nb\n", draft: "a\n") == [])
        #expect(InstructionsText.changedLines(saved: "same\n", draft: "same\n") == [])
    }

    @Test func aChangedLineCountsOnceAmongTheDifferences() {
        #expect(InstructionsText.differingLineCount("a\nb\nc\n", "a\nx\nc\n") == 1)
        #expect(InstructionsText.differingLineCount("a\nb\n", "a\nb\nc\nd\n") == 2)
        #expect(InstructionsText.differingLineCount("a\nb\nc\n", "x\ny\n") == 3)
        #expect(InstructionsText.differingLineCount("same\n", "same\n") == 0)
    }

    @Test(arguments: [
        ("", "- Never force-push.\n", "Added “Never force-push.”"),
        ("a\n", "a\nb\nc\n", "Added 2 lines"),
        ("a\n# Rules\nb\n", "a\nb\n", "Removed “Rules”"),
        ("a\nb\nc\n", "a\n", "Removed 2 lines"),
        ("1. Keep replies short.\n", "1. Keep replies very short.\n", "Edited “Keep replies very short.”"),
        ("a\nb\n", "x\ny\nz\n", "Edited 3 lines"),
        ("a\n", "a\n", "No changes"),
        ("a\n", "a\n\n", "Changed blank lines"),
    ])
    func aSaveSaysWhatItChanged(old: String, new: String, summary: String) {
        #expect(InstructionsText.summary(from: old, to: new) == summary)
    }

    @Test func aLongLineIsQuotedShort() {
        let line = "- " + String(repeating: "word ", count: 20)
        let summary = InstructionsText.summary(from: "", to: line)
        #expect(summary.hasSuffix("…”"))
        #expect(summary.count <= "Added “”".count + 48)
    }

    @Test(arguments: [
        ("## How I work", [InstructionsSpan(range: 0..<3, role: .headingMarker), InstructionsSpan(range: 3..<13, role: .heading)]),
        ("#", [InstructionsSpan(range: 0..<1, role: .headingMarker)]),
        ("#hashtag", []),
        ("- Prefer small commits.", [InstructionsSpan(range: 0..<1, role: .bullet)]),
        ("  * nested", [InstructionsSpan(range: 2..<3, role: .bullet)]),
        ("12. twelfth", [InstructionsSpan(range: 0..<3, role: .bullet)]),
        ("Run `swift test` before `git push`", [InstructionsSpan(range: 4..<16, role: .code), InstructionsSpan(range: 24..<34, role: .code)]),
        ("an `unclosed span", []),
        ("plain words", []),
    ])
    func theEditorHighlightsHeadingsBulletsAndCode(line: String, spans: [InstructionsSpan]) {
        #expect(InstructionsText.highlight(line: line) == spans)
    }
}

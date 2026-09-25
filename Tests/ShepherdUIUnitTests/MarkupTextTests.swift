import Foundation
import Testing
@testable import ShepherdUI

/// Settings descriptions carry inline markup: `code` for flags, files and tools, and **names**
/// for the options a sentence explains. Everything else is plain text, kept as written.
@Suite("Markup text")
struct MarkupTextTests {
    @Test func codeAndOptionNamesBecomeTheirOwnPieces() {
        #expect(NWMarkupTextParser.parse("passes no `--model` at all.") == [
            .plain("passes no "), .code("--model"), .plain(" at all."),
        ])
        #expect(NWMarkupTextParser.parse("**Remote default** starts clean. **Current branch** stacks.") == [
            .strong("Remote default"), .plain(" starts clean. "), .strong("Current branch"), .plain(" stacks."),
        ])
    }

    @Test(arguments: [
        "Compact 22 · Standard 28 · Comfortable 36 pt, for the sidebar and menus.",
        "Preselected in the New Agent sheet. “Use the agent's default” passes no model.",
        "Sidebar order; hold ⌘ to see the numbers.",
    ])
    func textWithoutMarkupStaysOnePlainPiece(source: String) {
        #expect(NWMarkupTextParser.parse(source) == [.plain(source)])
    }

    /// Underscores inside a code span are the tool's name, never emphasis.
    @Test func codeKeepsItsCharacters() {
        #expect(NWMarkupTextParser.parse("with `review_diff`.") == [.plain("with "), .code("review_diff"), .plain(".")])
        #expect(NWMarkupTextParser.parse("Runs `pi update --extensions` once a day.") == [
            .plain("Runs "), .code("pi update --extensions"), .plain(" once a day."),
        ])
    }
}

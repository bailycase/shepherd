import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// The bundled design skill teaches the format Shepherd enforces: its example board passes the
/// same checks a written board does, its element ids are the numbering Shepherd uses, and the
/// board names it prescribes are the ones the activity lines read.
@Suite("Design skill")
struct DesignSkillTests {
    /// The one html block in format.md.
    private static var exampleBoard: String {
        let text = DesignExtension.formatSource
        guard let start = text.range(of: "```html\n"), let end = text.range(of: "\n```", range: start.upperBound..<text.endIndex) else {
            return ""
        }
        return String(text[start.upperBound..<end.lowerBound]) + "\n"
    }

    @Test func theExampleBoardPassesShepherdsChecksWithoutWarnings() throws {
        let board = Self.exampleBoard
        #expect(!board.isEmpty)
        #expect(try DesignBoardCheck.check(board) == [])
    }

    /// format.md: "`<helmet>` is `0:0`, its `<style>` is `2:0/1`, `<main>` is `3:1`, and the
    /// `<h1>` is `4:1/0`."
    @Test(arguments: [(0, [0], "helmet"), (2, [0, 1], "style"), (3, [1], "main"), (4, [1, 0], "h1")])
    func theExampleIdsAreShepherdsNumbering(tid: Int, path: [Int], name: String) throws {
        let template = try #require(DesignTemplate(board: Self.exampleBoard))
        let element = try #require(template.elements.first { $0.tid == tid })
        #expect(element.path == path)
        #expect(element.name == name)
    }

    /// The skill's names ("A.dc.html", "A-phone.dc.html") are what "Drew 4 boards · 3 directions +
    /// phone" and "Updated A and A · phone" read.
    @Test func theSkillsBoardNamesAreTheOnesActivityLinesRead() {
        let skill = DesignExtension.skillSource
        for name in ["`A.dc.html`", "`B.dc.html`", "`C.dc.html`", "`A-phone.dc.html`", "\"A · phone\""] {
            #expect(skill.contains(name), "the skill names \(name)")
        }
        #expect(nativeBoardName("A-phone.dc.html") == "A · phone")
        #expect(nativeBoardSummary(["A.dc.html", "B.dc.html", "C.dc.html", "A-phone.dc.html"]) == "3 directions + phone")
    }
}

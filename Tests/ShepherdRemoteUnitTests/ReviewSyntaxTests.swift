import Testing
@testable import ShepherdRemote

/// The diff's syntax colors on a client without tree-sitter.
@Suite("Review syntax")
struct ReviewSyntaxTests {
    private func kinds(_ line: String, _ language: ReviewSyntax.Language) -> [String] {
        ReviewSyntax.spans(line, language: language).compactMap { span in span.kind.map { "\($0):\(span.text)" } }
    }

    @Test(arguments: [
        ("a/FleetView.swift", ReviewSyntax.Language.swift), ("web/app.tsx", .javaScript), ("main.go", .go), ("lib.rs", .rust),
        ("x.cpp", .c), ("tool.py", .python), ("Rakefile.rb", .ruby), ("run.sh", .shell), ("package.json", .json),
    ])
    func theExtensionPicksTheLanguage(path: String, language: ReviewSyntax.Language) {
        #expect(ReviewSyntax.language(forPath: path) == language)
    }

    @Test func unknownFilesStayPlain() {
        #expect(ReviewSyntax.language(forPath: "README.md") == nil)
        #expect(ReviewSyntax.language(forPath: "Makefile") == nil)
    }

    @Test(arguments: [
        "      if let configuration = connection.configuration {",
        "  Button(\"Reconnect\", systemImage: \"arrow.clockwise\") // retry",
        "let s = \"unterminated",
        "x = 'it\\'s' + 0x1F # done",
        "for i in 0..<10 { print(i) }",
        "",
    ])
    func spansJoinBackIntoTheLine(line: String) {
        for language in [ReviewSyntax.Language.swift, .python, .javaScript] {
            #expect(ReviewSyntax.spans(line, language: language).map(\.text).joined() == line)
        }
    }

    @Test func swiftKeywordsTypesCallsStringsAndComments() {
        #expect(kinds("if let x = HStack(spacing: 12) // gap", .swift) == [
            "keyword:if", "keyword:let", "type:HStack", "number:12", "comment:// gap",
        ])
        #expect(kinds("  Button(\"Reconnect\") { connection.reconnect() }", .swift) == [
            "type:Button", "string:\"Reconnect\"", "function:reconnect",
        ])
        #expect(kinds("@State private var n = 0", .swift) == ["keyword:@State", "keyword:private", "keyword:var", "number:0"])
    }

    @Test func aRangeEndsANumber() {
        #expect(kinds("0..<10", .swift) == ["number:0", "number:10"])
    }

    @Test func hashCommentsWhereTheLanguageUsesThem() {
        #expect(kinds("def f(): # note", .python) == ["keyword:def", "function:f", "comment:# note"])
        #expect(kinds("#if DEBUG", .swift) == ["keyword:#if", "type:DEBUG"])
    }

    @Test func blockCommentsOnOneLineAndTheirContinuations() {
        #expect(kinds("a /* b */ c", .c) == ["comment:/* b */"])
        #expect(kinds("   * continues", .javaScript) == ["comment:   * continues"])
    }
}

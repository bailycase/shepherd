import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A fence a reply is writing is colored by one session that keeps its parse tree: each chunk
/// colors from the first line it changed, and the colors stay those of a highlight of the whole
/// text. The whole highlight is the oracle (`CodeHighlightCache.render`, the highlight a finished
/// fence gets).
@Suite("Streaming code highlighting")
@MainActor
struct CodeHighlightSessionTests {
    private static func solid(_ hex: String) -> Color { Color(light: hex, dark: hex) }

    private let style = CodeHighlight.Style(
        comment: Self.solid("#565758"), string: Self.solid("#A1C592"), number: Self.solid("#CEB370"),
        keyword: Self.solid("#8892B5"), type: Self.solid("#A38FB5"), function: Self.solid("#8FB3AD")
    )

    struct Fixture: Sendable, CustomTestStringConvertible {
        let language: String
        let code: String
        var testDescription: String { language }
    }

    /// Each has a comment or string over several lines, so a chunk can end inside one.
    nonisolated static let fixtures = [
        Fixture(language: "python", code: #"""
        # the flock
        class Flock(Base):
            """A flock of sheep.

            Spans several lines."""

            def __init__(self, names, limit=42):
                self.names = [n for n in names if len(n) > 3]  # keep long names
                self.note = '''multi
                line string with "quotes" inside 🐑'''

            async def fetch(self, url):
                result = await client.get(
                    url,
                    params={"limit": self.limit, "name": 'sheep'},
                )
                return f"got {result} of {0x1F}"
        """#),
        Fixture(language: "go", code: #"""
        package main

        /* A flock
           spans lines */
        type Flock struct {
        	Names []string
        }

        // Count returns the number of long names.
        func (f *Flock) Count() int {
        	n := 0
        	for _, name := range f.Names {
        		if len(name) > 3 {
        			n++
        		}
        	}
        	return n + 0x1F
        }

        var banner = `raw string
        over two lines`

        func main() {
        	msg := fmt.Sprintf("count=%d", 3.14)
        }
        """#),
        Fixture(language: "javascript", code: #"""
        // the flock
        /**
         * A flock of sheep.
         */
        export class Flock extends Base {
          constructor(names, limit = 42) {
            super();
            this.names = names.filter((n) => n.length > 3);
            this.note = `multi
            line ${limit} template`;
          }

          async fetch(url) {
            const result = await fetchAll(url, {
              headers: { accept: 'application/json' },
            });
            return result.json();
          }
        }
        """#),
        Fixture(language: "json", code: #"""
        {
          "name": "flock",
          "sheep": [
            { "name": "bo", "age": 3, "wool": true },
            {
              "name": "shaun",
              "tags": ["clever", "leader"],
              "nested": { "deep": { "deeper": [1, 2.5, null] } }
            }
          ],
          "limit": 42
        }
        """#),
        Fixture(language: "rust", code: ##"""
        /// A flock of sheep.
        pub struct Flock {
            names: Vec<String>,
        }

        /* block
           comment */
        impl Flock {
            pub fn count(&self) -> usize {
                self.names.iter().filter(|n| n.len() > 3).count() + 0x1F
            }
        }

        fn main() {
            let raw = r#"raw "string" here"#;
            println!("{}", raw);
        }
        """##),
        Fixture(language: "ruby", code: #"""
        # the flock
        class Flock < Base
          def initialize(names, limit = 42)
            @names = names.select { |n| n.length > 3 }
            @note = <<~TEXT
              multi line
              heredoc #{limit}
            TEXT
          end

          def fetch(url)
            response = Client.get(url, limit: @limit,
                                  headers: { accept: "application/json" })
            JSON.parse(response.body)
          end
        end
        """#),
        Fixture(language: "bash", code: #"""
        #!/usr/bin/env bash
        # the flock
        names=("bo" "peep" 'shaun')

        count_long() {
          local n=0
          for name in "${names[@]}"; do
            if [ ${#name} -gt 3 ]; then
              n=$((n + 1))
            fi
          done
        }

        cat <<EOF
        multi line heredoc
        with $limit inside
        EOF
        """#),
    ]

    // MARK: Helpers

    /// `code` after each `size` unicode scalars, as a reply writes it.
    private func growth(of code: String, by size: Int) -> [String] {
        let scalars = Array(code.unicodeScalars)
        return stride(from: size, to: scalars.count + size, by: size).map { end in
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[0..<min(end, scalars.count)])
            return String(text)
        }
    }

    private func newlines(in text: String) -> Int { text.utf8.count { $0 == UInt8(ascii: "\n") } }

    /// The color of each UTF-16 unit.
    private func colors(of value: AttributedString) -> [Color?] {
        var units: [Color?] = []
        for run in value.runs {
            units += Array(repeating: run.foregroundColor, count: String(value[run.range].characters).utf16.count)
        }
        return units
    }

    private func colors(of colors: SHCodeColors, length: Int) -> [Color?] {
        var units = [Color?](repeating: nil, count: length)
        for span in colors.spans { for unit in span.range where unit < length { units[unit] = span.color } }
        return units
    }

    /// What the highlight of the whole text gives (a finished fence's), unit by unit.
    private func wholeColors(of text: String, language: String) throws -> [Color?] {
        let key = CodeHighlightCache.Key(code: text, language: language)
        return colors(of: try #require(CodeHighlightCache.render(key, style: style)))
    }

    /// Streams `chunks` the way a block does: each prefix with the lines it completes, and checks the
    /// colors after every advance against the highlight of the text held.
    private func expectWholeColors(_ chunks: [String], language: String) throws {
        let path = try #require(CodeHighlight.path(forFenceLanguage: language))
        let session = try #require(CodeHighlight.Session(path: path))
        var painted = SHCodeColors()
        var advances = 0
        for text in chunks {
            guard let update = session.advance(code: text, lines: newlines(in: text), style: style) else { continue }
            advances += 1
            painted.recolor(from: update.from, with: update.spans)
            #expect(text.hasPrefix(update.text))
            let held = update.text.utf16.count
            let expected = try wholeColors(of: update.text, language: language)
            let got = colors(of: painted, length: held)
            if got != expected {
                let first = zip(got, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? held
                Issue.record("\(language): the colors of \(update.text.utf8.count) bytes differ from a whole highlight at unit \(first) (colored from \(update.from))")
                return
            }
        }
        #expect(advances > 0)
    }

    // MARK: Same colors as a whole highlight

    /// Chunks of one scalar end inside every token, string and comment; the others end between lines
    /// or in the middle of one.
    @Test(arguments: fixtures, [1, 7, 64, 500])
    func aStreamedFenceHasTheColorsOfAWholeHighlightAfterEveryLine(fixture: Fixture, size: Int) throws {
        try expectWholeColors(growth(of: fixture.code, by: size), language: fixture.language)
    }

    /// The fence a reply has finished writing is colored as its whole highlight, last line included.
    @Test(arguments: fixtures)
    func theWholeFenceHasTheColorsOfAWholeHighlight(fixture: Fixture) throws {
        let path = try #require(CodeHighlight.path(forFenceLanguage: fixture.language))
        let session = try #require(CodeHighlight.Session(path: path))
        var painted = SHCodeColors()
        // The text written to its last line, whose end the next chunk would complete.
        for text in growth(of: fixture.code + "\n", by: 40) {
            guard let update = session.advance(code: text, lines: newlines(in: text), style: style) else { continue }
            painted.recolor(from: update.from, with: update.spans)
        }
        #expect(painted.spans.last.map { $0.range.upperBound <= fixture.code.utf16.count } == true)
        #expect(colors(of: painted, length: fixture.code.utf16.count) == (try wholeColors(of: fixture.code, language: fixture.language)))
    }

    /// Chunks cut where they must not matter: through a string, a line comment, a block comment and
    /// a raw string; the last two stay open over several chunks.
    @Test func chunksThatSplitAStringACommentAndAMultiLineConstructColorLikeTheWhole() throws {
        try expectWholeColors(
            ["var message = \"hel", "lo\"\n// split com", "ment\n/* block", "\ncomment ", "*/\nvar r = `raw", "\nstring`\nfunc f", "() {\n}\n"]
                .reduce(into: [String]()) { $0.append(($0.last ?? "") + $1) },
            language: "go")
        try expectWholeColors(
            ["def fo", "o(x):\n    s = \"\"\"doc", "\n    string\n", "    \"\"\"\n    ret", "urn x # d", "one\n"]
                .reduce(into: [String]()) { $0.append(($0.last ?? "") + $1) },
            language: "python")
    }

    /// A comment closed by the last line recolors the lines it closed over, which come before the
    /// lines the chunk added.
    @Test func closingACommentRecolorsTheLinesItCoversFromWhereItOpened() throws {
        let path = try #require(CodeHighlight.path(forFenceLanguage: "go"))
        let session = try #require(CodeHighlight.Session(path: path))
        let open = "package main\n\nfunc a() {}\n\n/* open\nstill open\n"
        _ = session.advance(code: open, lines: newlines(in: open), style: style)
        let closed = open + "*/\nvar x = 1\n"
        let update = try #require(session.advance(code: closed, lines: newlines(in: closed), style: style))
        let comment = (open as NSString).range(of: "/* open")
        #expect(update.from <= comment.location, "colored from \(update.from), the comment opens at \(comment.location)")
    }

    /// The session follows the fence: text that is no longer what it held starts it over.
    @Test func aFenceThatChangesIsColoredFromItsStartAgain() throws {
        let path = try #require(CodeHighlight.path(forFenceLanguage: "go"))
        let session = try #require(CodeHighlight.Session(path: path))
        let first = "var a = 1\nvar b = 2\nvar c = 3\n"
        #expect(session.advance(code: first, lines: 3, style: style) != nil)
        #expect(session.advance(code: first, lines: 3, style: style) == nil, "nothing new")

        let other = "// other\nfunc f() {}\n"
        let update = try #require(session.advance(code: other, lines: 2, style: style))
        #expect(update.from == 0 && update.text == "// other\nfunc f() {}")
        #expect(colors(of: SHCodeColors.painted(update), length: update.text.utf16.count)
                == (try wholeColors(of: update.text, language: "go")))
    }

    @Test func aLanguageWithoutAGrammarHasNoSession() {
        #expect(CodeHighlight.Session(path: "notes.txt") == nil)
    }

    // MARK: Work

    /// tree-sitter is given the lines a chunk adds, and a little around them, however long the fence
    /// is: the longest advance of a fence three times the length is no longer.
    @Test func aChunkIsParsedAndColoredInProportionToItsSizeNotTheFences() throws {
        func worst(lines: Int) throws -> (work: CodeHighlight.Session.Work, units: Int) {
            let code = (0..<lines).map { "def sheep\($0)(x): return x + \($0)  # count" }.joined(separator: "\n")
            let session = try #require(CodeHighlight.Session(path: "fence.py"))
            var worst = CodeHighlight.Session.Work()
            for text in growth(of: code + "\n", by: 512) {
                let before = session.work
                guard session.advance(code: text, lines: newlines(in: text), style: style) != nil else { continue }
                worst.parsed = max(worst.parsed, session.work.parsed - before.parsed)
                worst.colored = max(worst.colored, session.work.colored - before.colored)
            }
            return (worst, code.utf16.count)
        }
        let short = try worst(lines: 150), long = try worst(lines: 450)
        #expect(long.units > 3 * short.units - 100 && long.units > 15_000)
        #expect(long.work.parsed <= short.work.parsed + 512, "parsed \(long.work.parsed) units of \(long.units), after \(short.work.parsed) of \(short.units)")
        #expect(long.work.colored <= short.work.colored + 512, "colored \(long.work.colored) units of \(long.units), after \(short.work.colored) of \(short.units)")
        #expect(long.work.parsed < long.units / 3 && long.work.colored < long.units / 3)
    }
}

private extension SHCodeColors {
    /// The colors an update gives a fence that had none.
    static func painted(_ update: CodeHighlight.Session.Update) -> SHCodeColors {
        var colors = SHCodeColors()
        colors.recolor(from: update.from, with: update.spans)
        return colors
    }
}

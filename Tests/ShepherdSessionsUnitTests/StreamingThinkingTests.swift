import Testing
import ShepherdProtocol
@testable import ShepherdSessions

struct StreamingThinkingTests {
    /// Characterization against the settled projection: streaming must never change the
    /// whitespace or Unicode a reader sees when the same reply finishes.
    @Test(arguments: [
        "  First  \n \t\n\n  next  \nlast \t",
        "\r\nfirst\r\n\r\nsecond\r\n",
        " \u{0301}word\n\t\u{0301}next",
        "  👩🏽‍💻 thinks: cafe\u{0301}\n\nDone.  ",
        "\t\n\r\n  ",
    ])
    func everyScalarBoundaryMatchesSettledThinking(_ text: String) {
        var accumulator = StreamingThinking()
        var raw = ""
        for scalar in text.unicodeScalars {
            let chunk = String(scalar)
            raw += chunk
            accumulator.append(chunk)
            #expect(accumulator.normalized == RPCContentBlock.normalizedThinking(raw))
        }
    }

    @Test func blankSummaryPartsKeepOneBlankLine() {
        var accumulator = StreamingThinking()
        for chunk in ["  Thinking", "  \n", " \n\n", "  next", "  "] { accumulator.append(chunk) }
        #expect(accumulator.normalized == "Thinking  \n\n  next")
    }
}

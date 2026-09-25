import Foundation
import ShepherdProtocol
import ShepherdRemote
import Testing

/// Thinking the thread can show (DESIGN.md › Thread, Thinking): a disclosure when there is text
/// to read, a plain "Thought for Ns" line when the model shared none but it was timed, nothing
/// when it was neither; live thinking is drawn whatever it holds.
@Suite("Thinking presentation")
struct ThinkingPresentationTests {
    typealias F = Fixture

    enum Row: Equatable, CustomStringConvertible {
        case none
        case disclosure(String, seconds: Double?)
        case plain(seconds: Double)
        case live(String)

        var description: String {
            switch self {
            case .none: "none"
            case .disclosure(let text, let seconds): "disclosure(\(text), \(seconds.map { "\($0)" } ?? "nil"))"
            case .plain(let seconds): "plain(\(seconds))"
            case .live(let text): "live(\(text))"
            }
        }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        /// Each part's text and seconds, one assistant message each, with a read between.
        let parts: [(String, Double?)]
        let live: Bool
        let row: Row
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "text, timed", parts: [("Why?", 4)], live: false, row: .disclosure("Why?", seconds: 4)),
        Case(name: "text, untimed", parts: [("Why?", nil)], live: false, row: .disclosure("Why?", seconds: nil)),
        Case(name: "text, short", parts: [("Why?", 0.2)], live: false, row: .disclosure("Why?", seconds: 0.2)),
        Case(name: "no text, timed", parts: [("", 10)], live: false, row: .plain(seconds: 10)),
        Case(name: "whitespace, timed", parts: [(" \n\t", 10)], live: false, row: .plain(seconds: 10)),
        Case(name: "no text, untimed", parts: [("", nil)], live: false, row: .none),
        Case(name: "no text, short", parts: [("", 0.3)], live: false, row: .none),
        Case(name: "folded, one with text", parts: [("", 3), ("Then the tests.", 1)], live: false,
             row: .disclosure("Then the tests.", seconds: 4)),
        Case(name: "folded, only the texts", parts: [("a", nil), (" ", nil), ("c", nil)], live: false, row: .disclosure("a\n\nc", seconds: nil)),
        Case(name: "folded, no text, short together", parts: [("", 0.2), (" ", 0.2)], live: false, row: .none),
        Case(name: "folded, no text, timed together", parts: [("", 0.3), ("", 0.3)], live: false, row: .plain(seconds: 0.6)),
        Case(name: "live, text", parts: [("hmm", 2)], live: true, row: .live("hmm")),
        Case(name: "live, no text", parts: [("", 2)], live: true, row: .live("")),
        Case(name: "live, whitespace, untimed", parts: [("  ", nil)], live: true, row: .live("")),
    ]

    private static func messages(_ parts: [(String, Double?)], live: Bool) -> [NativeThreadMessage] {
        var messages: [NativeThreadMessage] = [F.assistant("Looking.")]
        for (index, part) in parts.enumerated() {
            if live, index == parts.count - 1 {
                var streaming = F.assistant("", thinking: part.0, status: "streaming", id: "a\(index)")
                streaming.thinkingSeconds = part.1
                streaming.timestamp = 5_000
                messages.append(streaming)
            } else {
                var message = F.assistant("", thinking: part.0, id: "a\(index)")
                message.thinkingSeconds = part.1
                messages += [message, F.tool("read", args: #"{"path":"\#(index).swift"}"#, id: "r\(index)", callID: "r\(index)")]
            }
        }
        return messages
    }

    private static func row(_ presentation: NativeTurnPresentation) -> Row {
        for item in presentation.items {
            guard case .thinking(_, let text, let seconds, let live, _) = item else { continue }
            if live { return .live(text) }
            if text.isEmpty { return .plain(seconds: seconds ?? -1) }
            return .disclosure(text, seconds: seconds)
        }
        return .none
    }

    @Test(arguments: cases)
    func thinkingShowsOnlyWhatItCarries(_ test: Case) {
        let presentation = nativeTurnPresentation(Self.messages(test.parts, live: test.live), live: test.live)
        let row = Self.row(presentation)
        if case .plain(let seconds) = row, case .plain(let expected) = test.row {
            #expect(abs(seconds - expected) < 1e-9)
        } else {
            #expect(row == test.row)
        }
    }

    /// Thinking left out still spends its place in the ids, so the rows after it keep theirs.
    @Test func leavingThinkingOutMovesNoOtherRow() {
        let shown = nativeTurnPresentation(Self.messages([("Why?", 4)], live: false) + [F.assistant("Done.")], live: false)
        let hidden = nativeTurnPresentation(Self.messages([("", nil)], live: false) + [F.assistant("Done.")], live: false)
        #expect(shown.items.count == hidden.items.count + 1)
        #expect(Array(shown.items.map(\.id).filter { !$0.hasPrefix("thinking") }) == hidden.items.map(\.id))
    }

    /// A reply that only thought (no text) and called a tool: kept once finished when the host
    /// timed it, so its plain line shows; never while it streams, nor when it was not timed.
    @Test(arguments: [(10, nil, true), (nil, nil, false), (0.3, nil, false), (10, "streaming", false)] as [(Double?, String?, Bool)])
    func aReplyThatOnlyThoughtStaysInItsTurnWhenTimed(seconds: Double?, status: String?, kept: Bool) {
        var thought = F.assistant("", thinking: "", status: status, id: "a")
        thought.thinkingSeconds = seconds
        let turns = nativeTurns([F.user("go", id: "u"), thought, F.tool("read", id: "r", callID: "r")])
        #expect(turns.last?.messages.map(\.entryID) == (kept ? ["a", "r"] : ["r"]))
    }

    @Test(arguments: [
        (nil, "Thought"), (0.3, "Thought"), (1, "Thought for 1 second"), (9.6, "Thought for 10 seconds"),
        (60, "Thought for 1 minute"), (64, "Thought for 1 minute 4 seconds"), (3600, "Thought for 1 hour"),
        (3720, "Thought for 1 hour 2 minutes"),
    ] as [(Double?, String)])
    func theSpokenDurationSaysItsUnits(seconds: Double?, text: String) {
        #expect(nativeThoughtSpokenText(seconds) == text)
    }

    @Test(arguments: [("", false), (" \n\t", false), ("a", true), ("\n x", true)])
    func readableThinkingIsAnythingButWhitespace(text: String, readable: Bool) {
        #expect(nativeThinkingIsReadable(text) == readable)
    }
}

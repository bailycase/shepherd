import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A skill or prompt template the user sent shows as its name and their words, not the text pi
/// expanded it to (SentCommandsA).
@Suite("Sent commands")
struct SentCommandTests {
    static func user(_ text: String, typed: String? = nil) -> NativeThreadMessage {
        var message = NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)])
        message.typedCommand = typed
        return message
    }

    static let skill = "<skill name=\"swiftui-specialist\" location=\"/skills/swiftui/SKILL.md\">\nReferences are relative to /skills/swiftui.\n\n# SwiftUI\n\nKey rows on ids.\n</skill>"

    @Test func aSkillShowsItsNameAndTheWordsAfterIt() throws {
        let bubble = try #require(nativeUserBubbles(Self.user(Self.skill + "\n\ncheck ThreadTurns.swift")).first)
        let command = try #require(bubble.command)
        #expect(command.kind == .skill && command.name == "swiftui-specialist" && command.location == "/skills/swiftui/SKILL.md")
        #expect(command.text == "# SwiftUI\n\nKey rows on ids.", "pi's references line is not the skill's")
        #expect(bubble.text == "check ThreadTurns.swift")
    }

    @Test func aSkillSentAloneHasNoWords() throws {
        let bubble = try #require(nativeUserBubbles(Self.user(Self.skill)).first)
        #expect(bubble.command?.name == "swiftui-specialist" && bubble.text.isEmpty)
    }

    /// pi's block ends at the first `</skill>` that ends the text or a blank line follows.
    @Test func aSkillWhoseBodyQuotesTheClosingTagStillParses() throws {
        let text = "<skill name=\"x\" location=\"/x\">\nsee </skill> here\n</skill> trailing\n</skill>\n\nnow"
        let command = try #require(NativeSentCommand.parse(text, typed: nil))
        #expect(command.text == "see </skill> here\n</skill> trailing" && command.words == "now")
    }

    @Test func aTemplateNeedsTheCommandTheHostRemembered() throws {
        let expanded = "Review the last commit for correctness."
        #expect(nativeUserBubbles(Self.user(expanded)).first?.command == nil, "without the typed command it is ordinary text")
        let bubble = try #require(nativeUserBubbles(Self.user(expanded, typed: "/review  the last commit")).first)
        #expect(bubble.command?.kind == .prompt && bubble.command?.name == "review" && bubble.command?.text == expanded)
        #expect(bubble.text == "the last commit")
    }

    /// A command sent while pi worked arrives from the queue: its part is what was typed, so the
    /// part split would show the command raw.
    @Test func aCommandFromTheQueueIsStillOneBubbleWithItsLine() throws {
        var message = Self.user("Review the last commit.", typed: "/review the last commit")
        message.origin = .queue(parts: [NativeQueuePart(id: nil, text: "/review the last commit", sentAt: 42, images: 0)])
        let bubbles = nativeUserBubbles(message)
        #expect(bubbles.count == 1 && bubbles.first?.command?.name == "review" && bubbles.first?.text == "the last commit")
        #expect(bubbles.first?.sentAt == 42, "it keeps the time it was queued")
    }

    @Test func anOrdinaryMessageOrAnUnexpandedCommandStaysText() {
        #expect(NativeSentCommand.parse("<skill name=\"x\">no location</skill>", typed: nil) == nil)
        #expect(NativeSentCommand.parse("/unknown thing", typed: "/unknown thing") == nil, "pi passed it through unchanged")
        #expect(NativeSentCommand.parse("hello", typed: "hello") == nil)
    }
}

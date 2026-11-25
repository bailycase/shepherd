import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Mac's words for the context details (GXContext, GXContextFull), taken from the host's
/// presentation once, where the model is made.
struct ContextDetailsWordsTests {
    static let split = NativeContextSplit(system: 6_800, instructions: 1_400, messages: 9_100, toolResults: 24_800, instructionFiles: ["AGENTS.md"])

    static func details(tokens: Int, split: NativeContextSplit?) -> NativeContextDetails {
        let context = NativeThreadContext(tokens: tokens, window: 200_000, autoCompactAt: 183_616, autoCompact: true, keepRecent: 20_000, split: split)
        return NativeContextDetails(context: context, model: "anthropic/claude-opus")
    }

    @Test func theSplitReadsAsTheBoardDoes() {
        let model = SHContextDetailsModel(Self.details(tokens: 42_000, split: Self.split))
        #expect(model.meta == "claude-opus, 200K")
        #expect(model.markLabel == "Compacts on its own at 184k")
        let instructions = model.rows.first { $0.part == .instructions }
        #expect(instructions?.label == "Instructions" && instructions?.detail == "AGENTS.md")
        #expect(model.rows.first { $0.part == .messages }?.detail == nil)
    }

    @Test func nearlyFullSaysTheAgentCompactsOnItsOwn() {
        let model = SHContextDetailsModel(Self.details(tokens: 178_000, split: Self.split))
        #expect(model.variant == .almostFull)
        #expect(model.note?.contains("The agent compacts on its own at 184k, before its next reply.") == true)
    }
}

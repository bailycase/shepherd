import Foundation
import ShepherdProtocol
import ShepherdRemote
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// A skill or prompt template the user sent (SentCommandsA, SentCommandsA-open), drawn from pi's
/// real skill block and a host's typed template through `nativeUserBubbles` and `UserTurn`, in
/// both appearances at text scale 1 and 1.3.
@Suite("Sent command previews", .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SentCommandPreviewTests {
    static let skillBody = """
        # SwiftUI specialist

        Consult the relevant reference before generating SwiftUI code that touches ForEach and List row identity: id: \\.self, indices, offsets, AnyView rows, inline filter or sort, cached collections, the List fast path.

        ## ForEach identity

        A row's identity must be stable across updates. Keying on an offset ties each row to its position, so an insert remounts every row after it.

        ## Environment

        Prefer @Entry for environment values and keep defaults cheap.
        """

    static func user(_ id: String, _ text: String, typed: String? = nil) -> NativeThreadMessage {
        var message = NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)])
        message.typedCommand = typed
        return message
    }

    static func skill(_ name: String, words: String?) -> String {
        "<skill name=\"\(name)\" location=\"/tmp/skills/\(name)/SKILL.md\">\nReferences are relative to /tmp/skills/\(name).\n\n\(skillBody)\n</skill>"
            + (words.map { "\n\n" + $0 } ?? "")
    }

    static func bubble(_ message: NativeThreadMessage) -> UserTurn.Bubble {
        let bubble = nativeUserBubbles(message)[0]
        return UserTurn.Bubble(text: bubble.text, images: 0, caption: "2:41 PM", pending: false, command: bubble.command)
    }

    @Test(arguments: ["closed", "open"])
    func sentCommands(_ state: String) async throws {
        let skill = Self.user("u1", Self.skill("swiftui-specialist", words: "Check ThreadTurns.swift for ForEach identity problems."))
        let prompt = Self.user("u2", "Review the last commit for correctness, tests and naming.", typed: "/review the last commit")
        let alone = Self.user("u3", Self.skill("useful-tests", words: nil))
        let opened = try #require(nativeUserBubbles(skill).first?.command)
        try await Preview.renderMatrix("thread-sent-commands-\(state)", size: CGSize(width: 880, height: 560)) {
            VStack(alignment: .leading, spacing: 24) {
                if state == "open" {
                    // The line opened: what a click on it shows.
                    SHUserBubble("Check ThreadTurns.swift for ForEach identity problems.", timestamp: "2:41 PM", revealed: true) {
                        SHSentCommand(kind: .skill, name: opened.name, meta: opened.meta, text: opened.text, expanded: true, open: {})
                    }
                } else {
                    UserTurn(bubbles: [Self.bubble(skill)], hover: MessageHover(hovering: true))
                }
                Text("Two rows key on \\.offset, so a streamed message remounts every row after it.").font(.sh(.body))
                if state == "open", let short = nativeUserBubbles(prompt).first?.command {
                    // A short template's box hugs its text.
                    SHUserBubble("the last commit") {
                        SHSentCommand(kind: .prompt, name: short.name, meta: short.meta, text: short.text, expanded: true)
                    }
                } else {
                    UserTurn(bubbles: [Self.bubble(prompt)])
                    UserTurn(bubbles: [Self.bubble(alone)])
                }
            }
            .frame(width: 820, alignment: .topLeading)
            .padding(30)
            .frame(width: 880, height: 560, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }
}

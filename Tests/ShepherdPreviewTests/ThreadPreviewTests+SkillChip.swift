import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

extension ThreadPreviewTests {
    /// A skill picked from the $ menu is an inline chip in the Mac composer's own field, where
    /// the "$de" was typed: at the start, mid-sentence, with a long name, and with the $ menu open
    /// over a draft that already holds one. Each draft is what `ComposerSkillToken` leaves.
    @Test func composerSkillChip() async throws {
        let commands = [
            NativeCommand(name: "review", description: "Open the review pane on working-tree changes"),
            NativeCommand(name: "skill:debug", description: "Find the root cause of a bug before changing code", source: "skill"),
            NativeCommand(name: "skill:deploy", description: "Ship the current branch to staging", source: "skill"),
            NativeCommand(name: "skill:swiftui-specialist-performance-and-accessibility-audit",
                          description: "Audit SwiftUI views for performance and accessibility", source: "skill"),
        ]
        // What was typed up to the "$", the skill picked there, and what was typed after it.
        func picked(_ typed: String, _ skill: String, then after: String) -> String {
            guard let token = ComposerCommandToken.token(in: typed) else { return typed }
            return ComposerSkillToken.draft(picking: skill, for: token) + after
        }
        let drafts = [
            picked("$deb", "skill:debug", then: "fix the login bug"),
            picked("fix the login bug $deb", "skill:debug", then: "and add a test"),
            picked("$swift", "skill:swiftui-specialist-performance-and-accessibility-audit", then: "on the thread list"),
            picked("fix the login bug $deb", "skill:debug", then: "then $dep"),
        ]
        func mac(_ draft: String) -> some View {
            let matches = NativeSlashMatches(draft: draft, commands: commands)
            return VStack(alignment: .leading, spacing: AppLayout.menuGap) {
                if let matches {
                    SHSlashMenu(commands: matches.commands.map(SlashMatchCache.row), total: matches.total, query: matches.query,
                                title: matches.title, selection: .constant(0)) { _ in }
                }
                SHComposer(isFocused: true) {
                    ComposerTextField(text: .constant(draft), placeholder: "Follow up, or / for commands…", label: "Message the agent",
                                      focus: .constant(false), attach: { _ in })
                } controls: {
                    Spacer(minLength: 8)
                    SHComposerActionButton(.send, enabled: true) {}
                }
            }
            .frame(width: 560)
        }
        let size = CGSize(width: 640, height: 900)
        try await Preview.render("composer-skill-chip", size: size) {
            VStack(alignment: .leading, spacing: 40) {
                ForEach(drafts.indices, id: \.self) { mac(drafts[$0]) }
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }

    /// An idle composer is as tall as its draft's lines, to its eight: one line, three, eight, thirty (eight, scrolling),
    /// and three with a skill chip. Only a field being edited measures from its words; these go through the cell.
    @Test func composerDraftHeights() async throws {
        func lines(_ count: Int) -> String { (1...count).map { "Line \($0) of the draft" }.joined(separator: "\n") }
        let drafts = [
            lines(1), lines(3), lines(8), lines(30),
            "fix the login bug\n/skill:debug and add a test\nthen ship it",
        ]
        func mac(_ draft: String) -> some View {
            SHComposer(isFocused: false) {
                ComposerTextField(text: .constant(draft), placeholder: "Follow up, or / for commands…", label: "Message the agent",
                                  focus: .constant(false), attach: { _ in })
            } controls: {
                Spacer(minLength: 8)
                SHComposerActionButton(.send, enabled: true) {}
            }
            .frame(width: 560)
        }
        let size = CGSize(width: 640, height: 1_040)
        try await Preview.render("composer-draft-heights", size: size) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(drafts.indices, id: \.self) { mac(drafts[$0]) }
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }
}

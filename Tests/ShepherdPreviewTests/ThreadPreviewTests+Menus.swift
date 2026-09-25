import Foundation
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

extension ThreadPreviewTests {
    /// The slash menu's rows as the SlashMenu board draws them, with a long name and a prompt.
    static let slashCommands = [
        NWSlashCommand(name: "review", description: "Open the review pane on working-tree changes"),
        NWSlashCommand(name: "resume", description: "Pick a previous session to continue", arguments: "[session]"),
        NWSlashCommand(name: "reload", description: "Reload extensions, skills and prompt templates"),
        NWSlashCommand(name: "release-notes", description: "Draft release notes from commits since the last tag", arguments: "[tag]", tag: "prompt"),
    ]

    /// The ModelPicker board's list, each row's second line the levels its model takes.
    static let boardModels = [
        NWModelSection(title: "Recent", options: [
            NWModelOption(id: "anthropic/claude-opus", title: "claude-opus", subtitle: "Off · Low · Medium · High", note: "200K", isCurrent: true),
            NWModelOption(id: "anthropic/claude-fable-5-1", title: "claude-fable-5-1", subtitle: "Off · Minimal · Low · Medium · High · Extra high · Max", note: "200K"),
        ]),
        NWModelSection(title: "anthropic", options: [
            NWModelOption(id: "anthropic/claude-sonnet", title: "claude-sonnet", subtitle: "Off · Minimal · Low · Medium · High", note: "200K"),
            NWModelOption(id: "anthropic/claude-haiku", title: "claude-haiku", subtitle: "No thinking", note: "200K"),
        ]),
    ]

    static func thinkingOptions(_ ids: [String]) -> [NWThinkingOption] {
        NativeThinkingLevel.levels(ids).map { NWThinkingOption(id: $0.id, title: $0.title, note: $0.note) }
    }

    /// The SlashMenu, ModelPicker and composer menu boards at the app's sizes: the slash menu over
    /// an 820pt composer card (typed "/s", a long name, a prompt, the highlighted row's ⏎), the
    /// model picker searched for "opus" over long ids, and the thinking menu for a model with all
    /// seven levels and one with pi's standard five.
    @Test func composerMenus() async throws {
        let column: CGFloat = 820
        let size = CGSize(width: 924, height: 1010)
        let commands = [
            NWSlashCommand(name: "shepherd-subagents-fleet", description: "Run a fleet of subagents over the plan's steps and gather their results",
                           arguments: "[plan]", tag: "skill"),
            NWSlashCommand(name: "shepherd-subagents", description: "Spawn a subagent for one task"),
            NWSlashCommand(name: "ship-it", description: "Commit, push and open a pull request for the working tree", tag: "prompt"),
            NWSlashCommand(name: "summarize-session", description: "Write a summary of this session into NOTES.md", tag: "prompt"),
        ]
        let opus = [
            NWModelSection(title: "Recent", options: [
                NWModelOption(id: "cpa/~anthropic/claude-opus-4-8-thinking-max", title: "~anthropic/claude-opus-4-8-thinking-max",
                              subtitle: "Off · Minimal · Low · Medium · High · Extra high · Max", note: "1M", isCurrent: true),
            ]),
            NWModelSection(title: "AG", options: [
                NWModelOption(id: "AG/claude-opus-4-6-thinking-extended-context", title: "claude-opus-4-6-thinking-extended-context",
                              subtitle: "Off · Minimal · Low · Medium · High", note: "200K"),
                NWModelOption(id: "AG/claude-opus-4-6", title: "claude-opus-4-6", subtitle: "Off · Minimal · Low · Medium · High · Extra high", note: "200K"),
            ]),
            NWModelSection(title: "cpa", options: [
                NWModelOption(id: "cpa/~anthropic/claude-opus-4-5-20251101", title: "~anthropic/claude-opus-4-5-20251101",
                              subtitle: "Off · Minimal · Low · Medium · High", note: "200K"),
                NWModelOption(id: "cpa/~openrouter/anthropic/claude-opus-4.1", title: "~openrouter/anthropic/claude-opus-4.1",
                              subtitle: "No thinking", note: "200K"),
            ]),
        ]
        func card(_ draft: String) -> some View {
            NWComposer(isFocused: true) {
                Text(draft).font(.nw(.body)).foregroundStyle(Color.nw.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
            } controls: {
                Button {} label: { HStack(spacing: 6) { Text("/").font(.nwMono(12)); Text("commands") } }.buttonStyle(.nwComposerChip())
                Button {} label: {
                    HStack(spacing: 6) {
                        Text("~anthropic/claude-opus-4-8-thinking-max").font(.nw(.code)).lineLimit(1).truncationMode(.middle)
                        NWChipChevron()
                    }
                }
                .buttonStyle(.nwComposerChip())
                Spacer(minLength: 8)
                NWComposerActionButton(.send, enabled: true) {}
            }
        }
        try await Preview.render("composer-menus", size: size) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: AppLayout.menuGap) {
                    NWSlashMenu(commands: commands, total: 23, query: "s", selection: .constant(0)) { _ in }
                    card("/s")
                }
                .frame(width: column)
                VStack(alignment: .leading, spacing: AppLayout.menuGap) {
                    NWSlashMenu(commands: Self.slashCommands, total: 23, query: "re", selection: .constant(3)) { _ in }
                    card("/re")
                }
                .frame(width: column)
                HStack(alignment: .bottom, spacing: 20) {
                    NWModelPicker(query: .constant("opus"), sections: opus, selection: .constant(1), shortcut: "⇧⌘M",
                                  onChoose: { _ in }, onClose: {})
                    NWThinkingMenu(options: Self.thinkingOptions(["off", "minimal", "low", "medium", "high", "xhigh", "max"]),
                                   current: "xhigh", onChoose: { _ in }, onClose: {})
                    NWThinkingMenu(options: Self.thinkingOptions(["off", "minimal", "low", "medium", "high"]),
                                   current: "medium", onChoose: { _ in }, onClose: {})
                }
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }
}


import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

extension ThreadPreviewTests {
    /// "/" and "$" anywhere in a draft, Mac and touch side by side, each menu derived from the
    /// draft by `NativeSlashMatches`: "/" at the start, "/" mid-draft, "$" mid-draft, and what
    /// choosing a command leaves in the field (a skill becomes a chip: `composerSkillChip`).
    @Test func composerCommandTokens() async throws {
        let commands = [
            NativeCommand(name: "review", description: "Open the review pane on working-tree changes"),
            NativeCommand(name: "release-notes", description: "Draft release notes from commits since the last tag", source: "prompt", arguments: "[tag]"),
            NativeCommand(name: "skill:debug", description: "Find the root cause of a bug before changing code", source: "skill"),
            NativeCommand(name: "skill:design-review", description: "Check a UI change against its board", source: "skill"),
            NativeCommand(name: "skill:deploy", description: "Ship the current branch to staging", source: "skill"),
        ]
        let states: [(draft: String, chosen: String?)] = [
            ("/re", nil), ("fix the login bug, then /rev", nil), ("fix the login bug $de", nil), ("/rev", "review"),
        ]
        func text(_ s: String) -> some View {
            Text(s.isEmpty ? " " : s).font(.sh(.body)).foregroundStyle(Color.sh.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
        }
        func mac(_ state: (draft: String, chosen: String?)) -> some View {
            let matches = NativeSlashMatches(draft: state.draft, commands: commands)
            let draft = state.chosen.flatMap { name in commands.first { $0.name == name } }.flatMap { matches?.completion($0) } ?? state.draft
            return VStack(alignment: .leading, spacing: AppLayout.menuGap) {
                if state.chosen == nil, let matches {
                    SHSlashMenu(commands: matches.commands.map(SlashMatchCache.row), total: matches.total, query: matches.query,
                                title: matches.title, selection: .constant(0)) { _ in }
                }
                SHComposer(isFocused: true) { text(draft) } controls: {
                    Spacer(minLength: 8)
                    SHComposerActionButton(.send, enabled: true) {}
                }
            }
            .frame(width: 560)
        }
        func touch(_ state: (draft: String, chosen: String?)) -> some View {
            let matches = NativeSlashMatches(draft: state.draft, commands: commands)
            let draft = state.chosen.flatMap { name in commands.first { $0.name == name } }.flatMap { matches?.completion($0) } ?? state.draft
            return VStack(alignment: .leading, spacing: SH.Space.m) {
                if state.chosen == nil, let matches {
                    SHTouchCommandList(commands: matches.commands.map {
                        SHTouchCommand(name: $0.name, description: $0.description, arguments: $0.arguments, tag: NativeSlashMatches.tag($0))
                    }, total: matches.total, query: matches.query, title: matches.title, wide: false) { _ in }
                }
                SHCapsuleComposer { text(draft) } action: { SHComposerActionButton(.send, enabled: true) {} }
            }
            .frame(width: 390)
        }
        let size = CGSize(width: 1100, height: 1500)
        try await Preview.render("composer-command-tokens", size: size) {
            VStack(alignment: .leading, spacing: 40) {
                ForEach(states.indices, id: \.self) { i in
                    HStack(alignment: .bottom, spacing: 40) { mac(states[i]); touch(states[i]) }
                }
            }
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }
}

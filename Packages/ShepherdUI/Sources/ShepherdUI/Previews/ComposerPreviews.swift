import SwiftUI

private struct NWPreviewComposerControls: View {
    var stop = false

    var body: some View {
        Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
            .accessibilityLabel("Attach file")
        Button {} label: { HStack(spacing: NW.Space.s) { Text("/").font(.nwMono(12)); Text("commands") } }.buttonStyle(.nwComposerChip())
        Button {} label: { HStack(spacing: NW.Space.s) { Text("claude-opus").font(.nwMono(12)); NWChipChevron() } }.buttonStyle(.nwComposerChip())
        Spacer(minLength: NW.Space.m)
        NWComposerActionButton(stop ? .stop : .send, enabled: stop) {}
    }
}

#Preview("Composer") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWComposer(isFocused: false) {
                Text("Follow up, or / for commands…").font(.nw(.body)).foregroundStyle(.nw.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: { NWPreviewComposerControls() }
            NWComposer(isFocused: true) {
                NWAttachmentChip("thread-spacing.png", thumbnail: Image(systemName: "photo")) {}
            } field: {
                Text("Match the spacing in this screenshot").font(.nw(.body)).frame(maxWidth: .infinity, alignment: .leading)
            } controls: { NWPreviewComposerControls(stop: true) }
        }
        .frame(width: 600)
    }
}

#Preview("Menus") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWSlashMenu(commands: [
                NWSlashCommand(name: "review", description: "Open the review pane on working-tree changes"),
                NWSlashCommand(name: "resume", description: "Pick a previous session to continue", arguments: "[session]"),
                NWSlashCommand(name: "release-notes", description: "Draft release notes since the last tag", arguments: "[tag]", tag: "prompt"),
            ], total: 23, query: "re", selection: .constant(0)) { _ in }
            HStack(alignment: .top, spacing: NW.Space.xl) {
                NWModelPicker(query: .constant(""), sections: [
                    NWModelSection(title: "Recent", options: [NWModelOption(id: "a/claude-opus", title: "claude-opus", isCurrent: true)]),
                    NWModelSection(title: "Anthropic", options: [NWModelOption(id: "a/claude-haiku", title: "claude-haiku", note: "200K")]),
                ], selection: .constant(0), onChoose: { _ in }, onClose: {})
                NWThinkingMenu(options: [
                    NWThinkingOption(id: "off", title: "Off"), NWThinkingOption(id: "low", title: "Low", note: "quick"),
                    NWThinkingOption(id: "medium", title: "Medium", note: "default"), NWThinkingOption(id: "high", title: "High", note: "slower, deeper"),
                ], current: "medium", onChoose: { _ in }, onClose: {})
            }
        }
    }
}

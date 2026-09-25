import SwiftUI

private struct NWPreviewComposerControls: View {
    var stop = false
    /// Working with a draft: Stop outlined beside Send.
    var draft = false

    var body: some View {
        Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
            .accessibilityLabel("Attach file")
        Button {} label: { HStack(spacing: NW.Space.s) { Text("/").font(.nwMono(12)); Text("commands") } }.buttonStyle(.nwComposerChip())
        Button {} label: { HStack(spacing: NW.Space.s) { Text("claude-opus").font(.nwMono(12)); NWChipChevron() } }.buttonStyle(.nwComposerChip())
        Spacer(minLength: NW.Space.m)
        if draft {
            HStack(spacing: NW.Space.s) {
                NWComposerActionButton(.stop, outlined: true) {}
                NWComposerActionButton(.send, ringed: true) {}
            }
        } else {
            NWComposerActionButton(stop ? .stop : .send, enabled: stop) {}
        }
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
            NWComposer(isFocused: true) {
                Text("Keep the PR title under 60 characters").font(.nw(.body)).frame(maxWidth: .infinity, alignment: .leading)
            } controls: { NWPreviewComposerControls(draft: true) }
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

#Preview("Up next") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWQueueStack(count: 3, collapsed: false, onToggle: {}) {
                NWQueueRow("Don’t touch the migrations in this PR.", kind: .steering, actions: NWQueueRowActions(back: {}))
                NWQueueRow("Also cover partial refunds in the tests.", kind: .queued(number: 1),
                           actions: NWQueueRowActions(steer: {}, edit: {}, delete: {}))
                NWQueueRow("Use table-driven tests, like ledger_test.go.", kind: .queued(number: 2), hovering: true,
                           actions: NWQueueRowActions(steer: {}, steerShortcut: "⌘↩", edit: {}, delete: {}, deleteShortcut: "⌫"),
                           drag: NWQueueDrag(changed: { _ in }, ended: { _ in }))
                NWQueueDeletedRow(deleted: "Then open a draft PR.") {}
            } options: {
                Button("Steer all now") {}
            }
            NWQueueStack(count: 1, collapsed: false, onToggle: {}) {
                NWQueueEditor(number: 1, text: .constant("Also cover partial refunds and refunds of a refund in the tests."),
                              onSave: {}, onCancel: {})
            } options: { EmptyView() }
            NWQueueStack(count: 6, collapsed: false, onToggle: {}) {
                NWQueueRow("Make this full width on phones", attachments: [NWQueueAttachment(id: "1", name: "checkout.png")],
                           kind: .queued(number: 1))
                NWQueueRow("Then open a draft PR.", kind: .queued(number: 2), focused: true)
                NWQueueMoreRow(hidden: 4, expanded: false) {}
            } options: { EmptyView() }
            NWQueueStack(count: 2, collapsed: true, onToggle: {}) { EmptyView() } options: { EmptyView() }
        }
        .frame(width: 520)
    }
}

#Preview("Send menu") {
    NWPreviewBoth {
        NWSendMenu(options: [
            NWSendOption(id: "queue", title: "Queue", detail: "Goes when the agent finishes this turn.", glyph: .queue, shortcut: "↩"),
            NWSendOption(id: "steer", title: "Steer now", detail: "Lands once the agent’s current tool calls finish, before its next step.",
                         glyph: .symbol("arrow.turn.down.right"), shortcut: "⌘↩"),
        ], onChoose: { _ in }, onClose: {})
    }
}

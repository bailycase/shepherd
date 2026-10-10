import SwiftUI

private struct NWPreviewComposerControls: View {
    var stop = false
    /// Working with a draft: Send, as an idle composer's.
    var draft = false

    var body: some View {
        Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
            .accessibilityLabel("Attach file")
        Button {} label: { NWModelSettingsLabel(model: "claude-opus", thinking: "Medium") }.buttonStyle(.nwComposerChip())
        Spacer(minLength: NW.Space.m)
        Button {} label: { NWComposerBranchLabel(branch: "agent/swiftui-previews", changes: 3) }.buttonStyle(.nwComposerChip())
        if draft {
            NWComposerActionButton(.send, ringed: true) {}
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

/// NWDesignTool › Chat composer: the regular size (New design, no ring before a conversation)
/// and the compact size of a 420pt chat pane, whose chips drop their words.
private struct NWPreviewSizedControls: View {
    var ring = false
    @Environment(\.nwComposerSize) private var size

    var body: some View {
        Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
            .accessibilityLabel("Attach file")
        Button {} label: { NWModelSettingsLabel(model: "claude-opus", thinking: size == .compact ? nil : "Medium") }
            .buttonStyle(.nwComposerChip())
        Spacer(minLength: NW.Space.m)
        if ring { NWContextRing(.fill(0.34, .calm)) }
        NWComposerActionButton(.send, enabled: false) {}
    }
}

#Preview("Composer sizes") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWComposer(isFocused: true) {
                Text("A checkout funnel dashboard for the product team…").font(.nw(.body)).foregroundStyle(.nw.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: { NWPreviewSizedControls() }
            .frame(width: 720)
            NWComposer(isFocused: false) {
                Text("Describe a change, or click something on the canvas to comment…").font(.nw(.body))
                    .foregroundStyle(.nw.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: { NWPreviewSizedControls(ring: true) }
            .frame(width: 392)
            .nwComposerSize(.compact)
        }
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
                    NWModelSection(title: "Recent", options: [
                        NWModelOption(id: "a/claude-opus", title: "claude-opus", isCurrent: true),
                        NWModelOption(id: "a/claude-sonnet", title: "claude-sonnet", fast: true),
                    ]),
                    NWModelSection(title: "Anthropic", options: [NWModelOption(id: "a/claude-haiku", title: "claude-haiku", note: "200K")]),
                ], selection: .constant(0), onChoose: { _ in }, onClose: {})
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
            NWSendOption(id: "wait", title: "Wait for the turn to end", detail: "Goes when the agent finishes this turn.",
                         glyph: .queue, shortcut: "↩"),
            NWSendOption(id: "now", title: "Steer now", detail: "Stops what the agent is doing and sends this at once.",
                         glyph: .symbol("arrow.turn.down.right"), shortcut: "⌘↩"),
        ], onChoose: { _ in }, onClose: {})
    }
}

#Preview("Question head") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWQuestionHead {}
            NWQuestionHead(count: 2) {}
            NWQuestionHiddenLine(question: "How should I handle Horizon’s uncommitted edits?") {}
        }
        .frame(width: 600)
    }
}

/// A dock with its own picks and focus, as the app hosts it.
struct NWQuestionDockSample: View {
    let content: NWQuestionDockContent
    @State private var selection: NWQuestionDockSelection
    @FocusState private var focus: NWQuestionDockField?

    init(_ content: NWQuestionDockContent, selection: NWQuestionDockSelection = NWQuestionDockSelection()) {
        self.content = content
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NWQuestionDock(content, selection: $selection, focus: $focus, answerEnabled: selection.picked != nil || !selection.text.isEmpty,
                       answer: { _ in }, hide: {})
    }
}

#Preview("Question dock") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWQuestionDockSample(NWQuestionDockContent(
                question: "How should I handle Horizon’s uncommitted edits?", kind: .choice,
                options: [
                    NWQuestionDockOption(number: 1, title: "Compare, keep what’s unique, then go through GitHub",
                                         detail: "Diff the 11 files against current master. Nothing on Horizon is overwritten.", recommended: true),
                    NWQuestionDockOption(number: 2, title: "Leave Horizon alone and deploy from a clean checkout",
                                         detail: "Horizon keeps its edits as they are."),
                ]), selection: NWQuestionDockSelection(picked: 1))
            NWQuestionDockSample(NWQuestionDockContent(
                question: "Is this a regression from #231?", kind: .yesNo,
                options: [NWQuestionDockOption(number: 1, title: "Yes", recommended: true), NWQuestionDockOption(number: 2, title: "No")],
                showsAnswer: false))
            NWQuestionDockSample(NWQuestionDockContent(
                question: "How long should refund events stay in the outbox?", kind: .open))
            NWQuestionDockHidden(question: "How should I handle Horizon’s uncommitted edits?") {}
        }
        .frame(width: 600)
    }
}

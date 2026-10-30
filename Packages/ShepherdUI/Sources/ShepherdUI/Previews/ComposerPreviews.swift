import SwiftUI

private struct SHPreviewComposerControls: View {
    var stop = false
    /// Working with a draft: Send, as an idle composer's.
    var draft = false

    var body: some View {
        Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.shIcon(size: SHComposerMetrics.chipHeight))
            .accessibilityLabel("Attach file")
        Button {} label: { SHModelSettingsLabel(model: "claude-opus", thinking: "Medium") }.buttonStyle(.shComposerChip())
        Spacer(minLength: SH.Space.m)
        Button {} label: { SHComposerBranchLabel(branch: "agent/swiftui-previews", changes: 3) }.buttonStyle(.shComposerChip())
        if draft {
            SHComposerActionButton(.send, ringed: true) {}
        } else {
            SHComposerActionButton(stop ? .stop : .send, enabled: stop) {}
        }
    }
}

#Preview("Composer") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xl) {
            SHComposer(isFocused: false) {
                Text("Follow up, or / for commands…").font(.sh(.body)).foregroundStyle(.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: { SHPreviewComposerControls() }
            SHComposer(isFocused: true) {
                SHAttachmentChip("thread-spacing.png", thumbnail: Image(systemName: "photo")) {}
            } field: {
                Text("Match the spacing in this screenshot").font(.sh(.body)).frame(maxWidth: .infinity, alignment: .leading)
            } controls: { SHPreviewComposerControls(stop: true) }
            SHComposer(isFocused: true) {
                Text("Keep the PR title under 60 characters").font(.sh(.body)).frame(maxWidth: .infinity, alignment: .leading)
            } controls: { SHPreviewComposerControls(draft: true) }
        }
        .frame(width: 600)
    }
}

/// SHDesignTool › Chat composer: the regular size (New design, no ring before a conversation)
/// and the compact size of a 420pt chat pane, whose chips drop their words.
private struct SHPreviewSizedControls: View {
    var ring = false
    @Environment(\.shComposerSize) private var size

    var body: some View {
        Button {} label: { Image(systemName: "paperclip") }.buttonStyle(.shIcon(size: SHComposerMetrics.chipHeight))
            .accessibilityLabel("Attach file")
        Button {} label: { SHModelSettingsLabel(model: "claude-opus", thinking: size == .compact ? nil : "Medium") }
            .buttonStyle(.shComposerChip())
        Spacer(minLength: SH.Space.m)
        if ring { SHContextRing(.fill(0.34, .calm)) }
        SHComposerActionButton(.send, enabled: false) {}
    }
}

#Preview("Composer sizes") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHComposer(isFocused: true) {
                Text("A checkout funnel dashboard for the product team…").font(.sh(.body)).foregroundStyle(.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: { SHPreviewSizedControls() }
            .frame(width: 720)
            SHComposer(isFocused: false) {
                Text("Describe a change, or click something on the canvas to comment…").font(.sh(.body))
                    .foregroundStyle(.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: { SHPreviewSizedControls(ring: true) }
            .frame(width: 392)
            .shComposerSize(.compact)
        }
    }
}

#Preview("Menus") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHSlashMenu(commands: [
                SHSlashCommand(name: "review", description: "Open the review pane on working-tree changes"),
                SHSlashCommand(name: "resume", description: "Pick a previous session to continue", arguments: "[session]"),
                SHSlashCommand(name: "release-notes", description: "Draft release notes since the last tag", arguments: "[tag]", tag: "prompt"),
            ], total: 23, query: "re", selection: .constant(0)) { _ in }
            HStack(alignment: .top, spacing: SH.Space.xl) {
                SHModelPicker(query: .constant(""), sections: [
                    SHModelSection(title: "Recent", options: [
                        SHModelOption(id: "a/claude-opus", title: "claude-opus", isCurrent: true),
                        SHModelOption(id: "a/claude-sonnet", title: "claude-sonnet", fast: true),
                    ]),
                    SHModelSection(title: "Anthropic", options: [SHModelOption(id: "a/claude-haiku", title: "claude-haiku", note: "200K")]),
                ], selection: .constant(0), onChoose: { _ in }, onClose: {})
            }
        }
    }
}

#Preview("Up next") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHQueueStack(count: 3, collapsed: false, onToggle: {}) {
                SHQueueRow("Don’t touch the migrations in this PR.", kind: .steering, actions: SHQueueRowActions(back: {}))
                SHQueueRow("Also cover partial refunds in the tests.", kind: .queued(number: 1),
                           actions: SHQueueRowActions(steer: {}, edit: {}, delete: {}))
                SHQueueRow("Use table-driven tests, like ledger_test.go.", kind: .queued(number: 2), hovering: true,
                           actions: SHQueueRowActions(steer: {}, steerShortcut: "⌘↩", edit: {}, delete: {}, deleteShortcut: "⌫"),
                           drag: SHQueueDrag(changed: { _ in }, ended: { _ in }))
                SHQueueDeletedRow(deleted: "Then open a draft PR.") {}
            } options: {
                Button("Steer all now") {}
            }
            SHQueueStack(count: 1, collapsed: false, onToggle: {}) {
                SHQueueEditor(number: 1, text: .constant("Also cover partial refunds and refunds of a refund in the tests."),
                              onSave: {}, onCancel: {})
            } options: { EmptyView() }
            SHQueueStack(count: 6, collapsed: false, onToggle: {}) {
                SHQueueRow("Make this full width on phones", attachments: [SHQueueAttachment(id: "1", name: "checkout.png")],
                           kind: .queued(number: 1))
                SHQueueRow("Then open a draft PR.", kind: .queued(number: 2), focused: true)
                SHQueueMoreRow(hidden: 4, expanded: false) {}
            } options: { EmptyView() }
            SHQueueStack(count: 2, collapsed: true, onToggle: {}) { EmptyView() } options: { EmptyView() }
        }
        .frame(width: 520)
    }
}

#Preview("Send menu") {
    SHPreviewBoth {
        SHSendMenu(options: [
            SHSendOption(id: "wait", title: "Wait for the turn to end", detail: "Goes when the agent finishes this turn.",
                         glyph: .queue, shortcut: "↩"),
            SHSendOption(id: "now", title: "Steer now", detail: "Stops what the agent is doing and sends this at once.",
                         glyph: .symbol("arrow.turn.down.right"), shortcut: "⌘↩"),
        ], onChoose: { _ in }, onClose: {})
    }
}

#Preview("Question head") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHQuestionHead(question: "How should I handle Horizon’s uncommitted edits?") {}
            SHQuestionHead(count: 3, question: "Are the threads a trigger starts ordinary threads or throwaway ones?") {}
            SHQuestionHiddenLine(question: "How should I handle Horizon’s uncommitted edits?") {}
        }
        .frame(width: 600)
    }
}

/// A dock with its own picks and focus, as the app hosts it.
struct SHQuestionDockSample: View {
    let content: SHQuestionDockContent
    @State private var selection: SHQuestionDockSelection
    @FocusState private var focus: SHQuestionDockField?

    init(_ content: SHQuestionDockContent, selection: SHQuestionDockSelection = SHQuestionDockSelection()) {
        self.content = content
        _selection = State(initialValue: selection)
    }

    var body: some View {
        SHQuestionDock(content, selection: $selection, focus: $focus, answerEnabled: selection.picked != nil || !selection.text.isEmpty,
                       answer: { _ in }, skip: {}, hide: {})
    }
}

#Preview("Question dock") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHQuestionDockSample(SHQuestionDockContent(
                count: 3, question: "Q2: are the threads a trigger starts ordinary threads or throwaway ones?",
                details: "Today an automation’s run agent is ephemeral. At every app launch, Shepherd deletes run agents and their layouts (`automationRunAgentIDs` in docs/data-flow.md).\n\nMy recommendation: triggered runs with a \"new thread\" destination become ordinary threads.",
                kind: .choice,
                options: [
                    SHQuestionDockOption(number: 1, title: "Ordinary threads that persist", recommended: true),
                    SHQuestionDockOption(number: 2, title: "Ephemeral like today"),
                    SHQuestionDockOption(number: 3, title: "Persist, but keep them in a separate Automations inbox, not the project sidebar"),
                ], allowsText: true), selection: SHQuestionDockSelection(picked: 1))
            SHQuestionDockSample(SHQuestionDockContent(
                question: "How should I handle Horizon’s uncommitted edits?", kind: .choice,
                options: [
                    SHQuestionDockOption(number: 1, title: "Compare, keep what’s unique, then go through GitHub",
                                         detail: "Diff the 11 files against current master. Nothing on Horizon is overwritten.", recommended: true),
                    SHQuestionDockOption(number: 2, title: "Leave Horizon alone and deploy from a clean checkout",
                                         detail: "Horizon keeps its edits as they are."),
                ]), selection: SHQuestionDockSelection(picked: 1))
            SHQuestionDockSample(SHQuestionDockContent(
                question: "Is this a regression from #231?", kind: .yesNo,
                options: [SHQuestionDockOption(number: 1, title: "Yes", recommended: true), SHQuestionDockOption(number: 2, title: "No")],
                showsAnswer: false))
            SHQuestionDockSample(SHQuestionDockContent(
                question: "How long should refund events stay in the outbox?", kind: .open))
            SHQuestionDockHidden(question: "How should I handle Horizon’s uncommitted edits?") {}
        }
        .frame(width: 600)
    }
}

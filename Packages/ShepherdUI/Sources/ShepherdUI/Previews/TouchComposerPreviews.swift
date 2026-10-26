import SwiftUI

#Preview("Touch queue") {
    SHPreviewBoth {
        SHTouchQueueCard(count: 3) {
            VStack(spacing: 0) {
                SHTouchQueueRow("Don't touch the migrations in this PR.", kind: .steering, back: {})
                SHTouchQueueRow("Don't touch the migrations in this PR.", kind: .steering, wide: true, back: {})
                    .overlay(alignment: .top) { SHHairline() }
                SHTouchQueueRow("Also cover partial refunds in the tests.", kind: .queued(number: 1), steer: {}).overlay(alignment: .top) { SHHairline() }
                SHTouchQueueRow("Then open a draft PR.", images: 2, kind: .queued(number: 2), held: true).overlay(alignment: .top) { SHHairline() }
                SHTouchQueueRow("Keep the PR title short", kind: .deleted, undo: {}).overlay(alignment: .top) { SHHairline() }
            }
        } options: {
            Button("Clear the queue", role: .destructive) {}
        }
        .frame(width: 360)
    }
}

#Preview("Touch queue, paused") {
    SHPreviewBoth {
        SHTouchQueueCard(count: 2, paused: "The queue waits for you: send it, steer it in, or send a new message.", resume: {}) {
            VStack(spacing: 0) {
                SHTouchQueueRow("Also cover partial refunds in the tests.", kind: .queued(number: 1))
                SHTouchQueueRow("Then open a draft PR.", kind: .queued(number: 2)).overlay(alignment: .top) { SHHairline() }
            }
        } options: {
            Button("Send all now") {}
        }
        .frame(width: 360)
    }
}

#Preview("Capsule composer") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xl) {
            SHCapsuleComposer {
                Text("Follow up…").font(.sh(.body)).foregroundStyle(.sh.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
            } action: {
                SHComposerActionButton(.send, enabled: false) {}
            }
            SHCapsuleComposer {
                Text("Keep the PR title short").font(.sh(.body)).frame(maxWidth: .infinity, alignment: .leading)
            } action: {
                SHComposerActionButton(.send) {}
            }
        }
        .frame(width: 360)
    }
}

#Preview("Command list") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xl) {
            SHTouchCommandList(commands: [
                SHTouchCommand(name: "review", description: "Open the review pane on working-tree changes"),
                SHTouchCommand(name: "resume", description: "Pick a previous session to continue", arguments: "[session]"),
                SHTouchCommand(name: "release-notes", description: "Draft release notes since the last tag", arguments: "[tag]", tag: "prompt"),
            ], total: 23, query: "re", wide: false) { _ in }
            SHTouchCommandList(commands: [
                SHTouchCommand(name: "reload", description: "Reload extensions, skills and prompt templates"),
            ], total: 23, query: "rel", wide: true) { _ in }
        }
        .frame(width: 480)
    }
}

#Preview("Question") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.xl) {
            SHQuestionCard(docked: false, count: 2, hide: {}) {
                Text("How should I handle Horizon's uncommitted edits?").font(.sh(.headline))
                SHQuestionOptionCard(number: 1, title: "Compare, keep what's unique, then go through GitHub",
                                     detail: "New branch and PR for anything not merged.", recommended: true, selected: true) {}
                SHQuestionOptionCard(number: 2, title: "Leave Horizon alone and deploy from a clean checkout") {}
                Button("Answer") {}.buttonStyle(.sh(.primary, size: .l))
            }
            SHQuestionCard(docked: true, hide: {}) {
                Text("Rename the new tokens, or replace the old ones everywhere?").font(.sh(.headline))
                SHQuestionOptionCard(number: 1, title: "Replace everywhere", selected: true) {}
                SHQuestionOptionCard(number: 2, title: "Rename new ones") {}
                Button("Answer") {}.buttonStyle(.shReviewBar(.primary))
            }
            SHQuestionCardHiddenLine(question: "How should I handle Horizon's uncommitted edits?") {}
        }
        .frame(width: 400)
    }
}

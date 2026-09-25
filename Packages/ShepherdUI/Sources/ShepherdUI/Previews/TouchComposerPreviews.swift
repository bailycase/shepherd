import SwiftUI

#Preview("Touch queue") {
    NWPreviewBoth {
        NWTouchQueueCard(count: 3) {
            VStack(spacing: 0) {
                NWTouchQueueRow("Don't touch the migrations in this PR.", kind: .steering, back: {})
                NWTouchQueueRow("Also cover partial refunds in the tests.", kind: .queued(number: 1)).overlay(alignment: .top) { NWHairline() }
                NWTouchQueueRow("Then open a draft PR.", images: 2, kind: .queued(number: 2), held: true).overlay(alignment: .top) { NWHairline() }
                NWTouchQueueRow("Keep the PR title short", kind: .deleted, undo: {}).overlay(alignment: .top) { NWHairline() }
            }
        } options: {
            Button("Clear the queue", role: .destructive) {}
        }
        .frame(width: 360)
    }
}

#Preview("Touch queue, paused") {
    NWPreviewBoth {
        NWTouchQueueCard(count: 2, paused: "The queue waits for you: send it, steer it in, or send a new message.", resume: {}) {
            VStack(spacing: 0) {
                NWTouchQueueRow("Also cover partial refunds in the tests.", kind: .queued(number: 1))
                NWTouchQueueRow("Then open a draft PR.", kind: .queued(number: 2)).overlay(alignment: .top) { NWHairline() }
            }
        } options: {
            Button("Send all now") {}
        }
        .frame(width: 360)
    }
}

#Preview("Capsule composer") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWCapsuleComposer(isFocused: false) {
                Text("Follow up…").font(.nw(.body)).foregroundStyle(.nw.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
            } action: {
                NWComposerActionButton(.send, enabled: false) {}
            }
            NWCapsuleComposer(isFocused: true) {
                Text("Keep the PR title short").font(.nw(.body)).frame(maxWidth: .infinity, alignment: .leading)
            } action: {
                NWComposerActionButton(.send) {}
            }
        }
        .frame(width: 360)
    }
}

#Preview("Command list") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWTouchCommandList(commands: [
                NWTouchCommand(name: "review", description: "Open the review pane on working-tree changes"),
                NWTouchCommand(name: "resume", description: "Pick a previous session to continue"),
                NWTouchCommand(name: "release-notes", description: "Draft release notes since the last tag", tag: "prompt"),
            ], total: 23, query: "re", wide: false) { _ in }
            NWTouchCommandList(commands: [
                NWTouchCommand(name: "reload", description: "Reload extensions, skills and prompt templates"),
            ], total: 23, query: "rel", wide: true) { _ in }
        }
        .frame(width: 480)
    }
}

#Preview("Question") {
    NWPreviewBoth {
        NWQuestionCard(docked: false, count: 2) {
            Text("How should I handle Horizon's uncommitted edits?").font(.nw(.headline))
            NWQuestionOptionCard(number: 1, title: "Compare, keep what's unique, then go through GitHub",
                                 detail: "New branch and PR for anything not merged.", recommended: true, selected: true)
            NWQuestionOptionCard(number: 2, title: "Leave Horizon alone and deploy from a clean checkout")
            Button("Answer") {}.buttonStyle(.nw(.primary, size: .l))
        }
        .frame(width: 400)
    }
}

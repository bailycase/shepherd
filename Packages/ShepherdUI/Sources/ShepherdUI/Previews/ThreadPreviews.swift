import SwiftUI

#Preview("Messages") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWUserBubble("Restyle the thread view to the spec and split the work however you like.", timestamp: "2:41 PM",
                         revealed: true)
            NWUserBubble("Also bump the tool row height to 28.", isQueued: true, onEdit: {}, onSendNow: {})
            HStack(spacing: NW.Space.s) {
                NWAttachmentChip("Spec.dc.html") {}
                NWAttachmentChip("screenshot.png", thumbnail: Image(systemName: "photo"))
            }
            NWAgentProse([
                .paragraph("Tool rows now derive a `ToolPreview` once from the call's arguments. Three things changed:"),
                .list(ordered: false, start: 1, items: [
                    NWProseListItem(text: "Bash rows show the command, truncated at the tail."),
                    NWProseListItem(text: "Read and edit rows show the path, truncated at the head."),
                ]),
                .code("enum ToolPreview {\n  case command(String)\n}", language: "swift"),
            ])
        }
        .frame(width: 640)
    }
}

#Preview("Thinking, footer, error") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWThinking("Thought for 4s", text: "", isExpanded: .constant(false))
            NWThinking("Thought for 6s", text: "I'll keep it a minimum, not a fixed height, so large text sizes still fit.", isExpanded: .constant(true))
            NWThinking(liveSince: Date().addingTimeInterval(-4))
            NWTurnFooter(meta: "2:44 PM · 3m 12s · 23 tool calls", link: "3 subagents", onLink: {}, onCopy: {}, onRetry: {},
                         revealed: true)
            NWTurnError("Model overloaded — the turn stopped after 6 tool calls.", retry: {})
            NWWorkingRow("Working…")
        }
        .frame(width: 480)
    }
}

#Preview("Activity lines") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            NWActivityLine(kind: .work, label: "Worked for 6m 40s", meta: "explored 13 files · edited 15 files · ran 22 commands · 5 failed") {}
            NWActivityLine(kind: .work, label: "Worked for 1m 42s", meta: "explored 7 files · edited 3 files", isExpanded: true) {}
            NWActivityRail {
                NWActivityLine(kind: .explore, label: "Explored 7 files", meta: "read 5 · search 2 · 0.9s") {}
            }
            NWActivityLine(kind: .edit, label: "Edited 3 files", meta: "+67 −46", isExpanded: true) {}
            NWActivityCalls([
                NWActivityCallRow(id: "1", label: "edit", detail: "Sources/ShepherdApp/DesktopNativeThreadView.swift", isPath: true, stat: "+58 −41"),
                NWActivityCallRow(id: "2", label: "edit", detail: "App/iOS/ThreadView.swift", isPath: true, stat: "+0 −4"),
            ], onSelect: { _ in }, onShowAll: { _ in })
            NWActivityLine(kind: .run, label: "Ran tests", meta: "swift test · exit 1 · 8.4s", status: .failed) {}
            NWActivityLine(kind: .run, label: "Building", meta: "xcodebuild -scheme 'Shepherd (Dev)' build",
                           status: .live(since: Date().addingTimeInterval(-12), tail: ["CompileSwift ThreadView.swift", "Linking Shepherd …"]))
        }
        .frame(width: 560)
    }
}

#Preview("Changes card") {
    NWPreviewBoth {
        NWChangesCard(title: "2 files changed", added: 70, removed: 45, files: [
            NWChangedFile(path: "Sources/ShepherdApp/ToolRow.swift", directory: "Sources/ShepherdApp/", name: "ToolRow.swift", status: .modified, added: 12, removed: 4),
            NWChangedFile(path: "Tests/ToolPreviewTests.swift", directory: "Tests/", name: "ToolPreviewTests.swift", status: .added, added: 58, removed: 41),
        ], onReview: {}, onOpen: { _ in })
        .frame(width: 560)
    }
}

import SwiftUI

#Preview("Messages") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWUserBubble("Restyle the thread view to the spec and split the work however you like.", timestamp: "2:41 PM",
                         revealed: true)
            NWQueueDivider(count: 2)
            NWUserBubble("Also bump the tool row height to 28.", timestamp: "2:44 PM", revealed: true)
            NWUserBubble("Use table-driven tests, like ledger_test.go.", timestamp: "2:47 PM", revealed: true, origin: .steered)
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

#Preview("Question record") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWQuestionRecord(question: "How should I handle Horizon’s uncommitted edits?",
                             title: "Compare, keep what’s unique, then go through GitHub", answered: true,
                             timestamp: "2:51 PM · answered", revealed: true)
            NWQuestionRecord(question: "Name for the release branch?", text: "release/2026-09", answered: true,
                             timestamp: "2:53 PM · answered", revealed: true)
            NWQuestionRecord(question: "Clear the session?", answered: false)
        }
        .frame(width: 640)
    }
}

#Preview("Rich prose") {
    NWPreviewBoth {
        NWAgentProse([
            .table(NWProseTable(
                alignments: [.leading, .trailing],
                header: ["Area", "Tools"],
                rows: [["Terminal panes", NWProseInline.attributed("`pane_list`, `pane_open`, `pane_run`")],
                       ["Notifications and review", NWProseInline.attributed("`notify`, `review_diff`")]],
                markdown: "| Area | Tools |")),
            .list(ordered: false, start: 1, items: [
                NWProseListItem(text: "Parse tables", task: .done),
                NWProseListItem(text: "Nest lists", task: .open, children: [
                    .list(ordered: true, start: 1, items: [NWProseListItem(text: "to any depth")]),
                ]),
            ]),
            .image(NWProseImage(alt: "Build status", source: "https://ci.example.com/badge.png")),
            .details(summary: "Full log", blocks: [.paragraph("41 tests passed.")]),
            .code("graph TD\n  A --> B", language: "mermaid"),
            .footnotes([NWProseFootnote(number: 1, text: "Gathered at the end of the message.")]),
        ])
        .frame(width: 640)
    }
}

#Preview("Thinking, footer, error") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWThinking("Thought for 4s", text: "Check the labels first.", isExpanded: .constant(false))
            NWThinking("Thought for 10s", text: "", isExpanded: .constant(false), spokenTitle: "Thought for 10 seconds")
            NWThinking("Thought for 6s", text: "I'll keep it a minimum, not a fixed height, so large text sizes still fit.", isExpanded: .constant(true))
            NWThinking("Thought", blocks: [
                .paragraph(AttributedString("Inspecting SSH config", attributes: AttributeContainer().inlinePresentationIntent(.stronglyEmphasized))),
                .paragraph(AttributedString("Checking ~/.ssh/config for the runner host…")),
            ], isExpanded: .constant(true))
            NWThinking.live()
            NWTurnFooter(meta: "2:44 PM · 3m 12s · 23 tool calls", link: "3 subagents", onLink: {}, onCopy: {}, onRetry: {},
                         revealed: true)
            NWJumpToLatest {}
        }
        .frame(width: 480)
    }
}

extension NWTurnError.Content {
    /// OpenAI refusing a key (TurnErrors › The error card).
    static let previewAuth = NWTurnError.Content(
        title: "OpenAI rejected the API key",
        message: [.text("Incorrect API key provided: "), .code("sk-svcac…fvMA"), .text(". You can find your API key at "),
                  .link(display: "platform.openai.com/account/api-keys", url: "https://platform.openai.com/account/api-keys"), .text(".")],
        chips: ["401", "authentication_error"], source: "gpt-6-astra · OpenAI", time: "5:54 PM", foldedMeta: "401 · 5:52 PM",
        facts: [.init("Provider", "OpenAI", mono: false), .init("Model", "gpt-6-astra"), .init("Host", "build-01"), .init("Status", "401"),
                .init("Type", "authentication_error"), .init("Code", "auth_unavailable"), .init("Request", "req_7f3c1a9e02b4"),
                .init("At", "5:54:31 PM")],
        body: [.plain("{\n  "), .key("\"message\""), .plain(": "), .string("\"Incorrect API key provided: "), .redacted("sk-svcac…fvMA"),
               .string(". You can find your API key at "), .link("https://platform.openai.com/account/api-keys"), .string(".\""),
               .plain(",\n  "), .key("\"type\""), .plain(": "), .string("\"authentication_error\""), .plain(",\n  "),
               .key("\"code\""), .plain(": "), .string("\"auth_unavailable\""), .plain("\n}")],
        copyText: "OpenAI rejected the API key")
}

#Preview("Turn errors") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            NWTurnError(.previewAuth, retry: {})
            NWTurnError(.previewAuth, detailsOpen: true, retry: {})
            NWTurnError(.previewAuth, folded: true)
            NWTurnError(NWTurnError.Content(glyph: "hourglass", title: "OpenAI didn’t respond in time", message: [.text("Request timed out.")],
                                            chips: ["timeout"], source: "gpt-6-astra · OpenAI", tries: "Tried 3 times over 31m", time: "6:02 PM"),
                        retry: {})
            NWRetryLine(count: "2 of 3") { _ in "OpenAI is overloaded · retrying in 8s" }
        }
        .frame(width: 760)
    }
}

#Preview("Activity lines") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            NWActivityLine(kind: .explore, label: "Explored 7 files", meta: "read 5 · search 2 · 0.9s") {}
            NWActivityLine(kind: .edit, label: "Edited 3 files", meta: "+67 −46", isExpanded: true) {}
            NWActivityCalls([
                NWActivityCallRow(id: "1", label: "edit", detail: "Sources/ShepherdApp/DesktopNativeThreadView.swift", isPath: true, stat: "+58 −41"),
                NWActivityCallRow(id: "2", label: "edit", detail: "App/iOS/ThreadView.swift", isPath: true, stat: "+0 −4"),
                NWActivityCallRow(id: "3", label: "edit", detail: "Tests/ShepherdAppTests/NativePresentationTests.swift", isPath: true, stat: "+9 −1"),
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

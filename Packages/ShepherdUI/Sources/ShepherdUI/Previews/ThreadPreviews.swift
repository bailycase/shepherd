import SwiftUI

#Preview("Messages") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHUserBubble("Restyle the thread view to the spec and split the work however you like.", timestamp: "2:41 PM",
                         revealed: true)
            SHQueueDivider(count: 2)
            SHUserBubble("Also bump the tool row height to 28.", timestamp: "2:44 PM", revealed: true)
            SHUserBubble("Use table-driven tests, like ledger_test.go.", timestamp: "2:47 PM", revealed: true, origin: .steered)
            HStack(spacing: SH.Space.s) {
                SHAttachmentChip("Spec.dc.html") {}
                SHAttachmentChip("screenshot.png", thumbnail: Image(systemName: "photo"))
            }
            SHAgentProse([
                .paragraph("Tool rows now derive a `ToolPreview` once from the call's arguments. Three things changed:"),
                .list(ordered: false, start: 1, items: [
                    SHProseListItem(text: "Bash rows show the command, truncated at the tail."),
                    SHProseListItem(text: "Read and edit rows show the path, truncated at the head."),
                ]),
                .code("enum ToolPreview {\n  case command(String)\n}", language: "swift"),
            ])
        }
        .frame(width: 640)
    }
}

#Preview("Question record") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHQuestionRecord(question: "How should I handle Horizon’s uncommitted edits?",
                             title: "Compare, keep what’s unique, then go through GitHub", answered: true,
                             timestamp: "2:51 PM · answered", revealed: true)
            SHQuestionRecord(question: "Name for the release branch?", text: "release/2026-09", answered: true,
                             timestamp: "2:53 PM · answered", revealed: true)
            SHQuestionRecord(question: "Clear the session?", answered: false)
        }
        .frame(width: 640)
    }
}

#Preview("Rich prose") {
    SHPreviewBoth {
        SHAgentProse([
            .table(SHProseTable(
                alignments: [.leading, .trailing],
                header: ["Area", "Tools"],
                rows: [["Terminals", SHProseInline.attributed("`terminal_list`, `terminal_open`, `terminal_run`")],
                       ["Notifications and review", SHProseInline.attributed("`notify`, `review_diff`")]],
                markdown: "| Area | Tools |")),
            .list(ordered: false, start: 1, items: [
                SHProseListItem(text: "Parse tables", task: .done),
                SHProseListItem(text: "Nest lists", task: .open, children: [
                    .list(ordered: true, start: 1, items: [SHProseListItem(text: "to any depth")]),
                ]),
            ]),
            .image(SHProseImage(alt: "Build status", source: "https://ci.example.com/badge.png")),
            .details(summary: "Full log", blocks: [.paragraph("41 tests passed.")]),
            .code("graph TD\n  A --> B", language: "mermaid"),
            .footnotes([SHProseFootnote(number: 1, text: "Gathered at the end of the message.")]),
        ])
        .frame(width: 640)
    }
}

#Preview("Thinking, footer, error") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHThinking("Thought for 4s", text: "Check the labels first.", isExpanded: .constant(false))
            SHThinking("Thought for 10s", text: "", isExpanded: .constant(false), spokenTitle: "Thought for 10 seconds")
            SHThinking("Thought for 6s", text: "I'll keep it a minimum, not a fixed height, so large text sizes still fit.", isExpanded: .constant(true))
            SHThinking("Thought", blocks: [
                .paragraph(AttributedString("Inspecting SSH config", attributes: AttributeContainer().inlinePresentationIntent(.stronglyEmphasized))),
                .paragraph(AttributedString("Checking ~/.ssh/config for the runner host…")),
            ], isExpanded: .constant(true))
            SHThinking.live()
            SHTurnFooter(meta: "2:44 PM · 3m 12s · 23 tool calls", link: "3 subagents", onLink: {}, onCopy: {}, onRetry: {},
                         revealed: true)
            SHJumpToLatest {}
        }
        .frame(width: 480)
    }
}

extension SHTurnError.Content {
    /// OpenAI refusing a key (TurnErrors › The error card).
    static let previewAuth = SHTurnError.Content(
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
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHTurnError(.previewAuth, retry: {})
            SHTurnError(.previewAuth, detailsOpen: true, retry: {})
            SHTurnError(.previewAuth, folded: true)
            SHTurnError(SHTurnError.Content(glyph: "hourglass", title: "OpenAI didn’t respond in time", message: [.text("Request timed out.")],
                                            chips: ["timeout"], source: "gpt-6-astra · OpenAI", tries: "Tried 3 times over 31m", time: "6:02 PM"),
                        retry: {})
            SHRetryLine(count: "2 of 3") { _ in "OpenAI is overloaded · retrying in 8s" }
        }
        .frame(width: 760)
    }
}

#Preview("Activity lines") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            SHActivityLine(kind: .explore, label: "Explored 7 files", meta: "read 5 · search 2 · 0.9s") {}
            SHActivityLine(kind: .edit, label: "Edited 3 files", meta: "+67 −46", isExpanded: true) {}
            SHActivityCalls([
                SHActivityCallRow(id: "1", label: "edit", detail: "Sources/ShepherdApp/DesktopNativeThreadView.swift", isPath: true, stat: "+58 −41"),
                SHActivityCallRow(id: "2", label: "edit", detail: "App/iOS/ThreadView.swift", isPath: true, stat: "+0 −4"),
                SHActivityCallRow(id: "3", label: "edit", detail: "Tests/ShepherdAppTests/NativePresentationTests.swift", isPath: true, stat: "+9 −1"),
            ], onSelect: { _ in }, onShowAll: { _ in })
            SHActivityLine(kind: .run, label: "Ran tests", meta: "swift test · exit 1 · 8.4s", status: .failed) {}
            SHActivityLine(kind: .run, label: "Building", meta: "xcodebuild -scheme 'Shepherd (Dev)' build",
                           status: .live(since: Date().addingTimeInterval(-12), tail: ["CompileSwift ThreadView.swift", "Linking Shepherd …"]))
            SHActivityLine(kind: .drew, label: "Drew 4 boards", meta: "3 directions + phone") {}
            SHActivityLine(kind: .checked, label: "Checked against acme-web", meta: "0 off-system values") {}
        }
        .frame(width: 560)
    }
}

/// A label wider than the line truncates (and drops its meta) instead of widening the thread.
#Preview("Activity lines, long labels") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            SHActivityLine(kind: .edit, label: "Updated withdrawals-mobile-approve, withdrawals-desktop-approve and withdrawals-claims-details",
                           meta: "edited") {}
            SHActivityLine(kind: .browser, label: "Opened localhost:5173/checkout/withdrawals/mobile/approve/review/summary in Browser", meta: "1.2s") {}
            SHActivityLine(kind: .other, label: "Used shepherd_child_message", meta: #"{"id":"native-48c1466f-3255-4d0a-9c1e-5b7f1e2a6b10","delivered":true}"#) {}
            SHActivityLine(kind: .explore, label: "Search failed", meta: "menuOpen|has-next-page|width:390px|<table|summary-row · invalid regular expression",
                           status: .failed) {}
        }
        .frame(width: 388)
    }
}

#Preview("Changes card") {
    SHPreviewBoth {
        SHChangesCard(title: "2 files changed", added: 70, removed: 45, files: [
            SHChangedFile(path: "Sources/ShepherdApp/ToolRow.swift", directory: "Sources/ShepherdApp/", name: "ToolRow.swift", status: .modified, added: 12, removed: 4),
            SHChangedFile(path: "Tests/ToolPreviewTests.swift", directory: "Tests/", name: "ToolPreviewTests.swift", status: .added, added: 58, removed: 41),
        ], onReview: {}, onOpen: { _ in })
        .frame(width: 560)
    }
}

#Preview("Response visibility") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xxl) {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                SHLiveLine("Waiting for response", since: .now.addingTimeInterval(-4), help: "Request sent. No reply from the model yet.")
                SHThinking.live(since: .now.addingTimeInterval(-18))
                SHThinking.live(since: .now.addingTimeInterval(-30), blocks: [.paragraph("**Choosing a screen for the composer**"),
                                                                             .paragraph("Compared keeping the composer under the thread.")],
                                isExpanded: .constant(true))
                SHActivityLine(kind: .edit, label: "Writing", meta: "App/iOS/Thread/DuoComposerPlacement.swift",
                               status: .live(since: .now.addingTimeInterval(-6), tail: []), received: "18 KB received")
                SHRetryLine(count: "2 of 3") { _ in "Anthropic returned 529 overloaded · retrying in 8s" }
            }
            .frame(width: 520)
            SHResponseTiming(SHResponseTimingModel(
                source: "claude-opus-4-5 · Anthropic", total: "45.0s", totalSeconds: 45, axisEnd: "45s",
                segments: [.init(label: "Waiting for response", value: "1.4s", seconds: 1.4, tone: .waiting),
                           .init(label: "Thinking", value: "30.4s", seconds: 30.4, tone: .thinking),
                           .init(label: "Writing the reply", value: "13.2s", seconds: 13.2, tone: .writing)],
                marks: [.init(label: "Request sent", value: "0s"), .init(label: "Headers received", value: "1.2s"),
                        .init(label: "First model event", value: "1.4s"), .init(label: "First visible text", value: "31.8s"),
                        .init(label: "Response ended", value: "45.0s")],
                usage: "14.2k in · 2.9k out",
                note: "The phases follow one another, so they add up to the total. Times are what this Mac saw."))
            .shPopover()
        }
    }
}

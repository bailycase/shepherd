import SwiftUI

// The context meter (ContextIdeas, ContextDetails, ContextFull, ContextCompacted) and compactions
// in the thread.

private let previewSplit = SHContextDetailsModel(
    variant: .split, title: "Context", meta: "claude-opus · 200k", total: "42k", ofWindow: "of 200k", trailing: "21%",
    segments: [.init(part: .system, fraction: 0.034), .init(part: .instructions, fraction: 0.007),
               .init(part: .messages, fraction: 0.0455), .init(part: .toolResults, fraction: 0.124)],
    mark: 0.92, markLabel: "auto-compact · 184k ↑",
    rows: [.init(part: .system, label: "System prompt and tools", value: "6.8k"), .init(part: .instructions, label: "Instructions · AGENTS.md", value: "1.4k"),
           .init(part: .messages, label: "Messages", value: "9.1k"), .init(part: .toolResults, label: "Tool results", value: "24.8k")],
    free: "158k",
    items: [.init(id: "a", kind: .file, label: "DesktopNativeThreadView.swift", value: "8.2k"),
            .init(id: "b", kind: .command, label: "swift test --filter Native…", value: "6.1k"),
            .init(id: "c", kind: .file, label: "ThreadView.swift", value: "3.4k")],
    footnote: "The total is the agent’s. The split is Shepherd’s estimate from the messages.")

private let previewFull = SHContextDetailsModel(
    variant: .almostFull, title: "Context almost full", total: "178k", ofWindow: "of 200k", trailing: "89%",
    segments: [.init(part: .system, fraction: 0.034), .init(part: .instructions, fraction: 0.007),
               .init(part: .messages, fraction: 0.158), .init(part: .toolResults, fraction: 0.691)],
    mark: 0.92, markLabel: "auto-compact · 184k ↑",
    note: "Tool results are 138k of it. The agent will compact on its own at 184k, before its next reply. Compact now to say what the summary should keep.")

#Preview("Context ring") {
    SHPreviewBoth {
        HStack(spacing: SH.Space.xl) {
            ForEach(Array([SHContextRingState.empty, .fill(0.21, .calm), .fill(0.68, .warning), .fill(0.89, .critical), .compacting, .estimated]
                .enumerated()), id: \.offset) { _, state in
                SHContextMeterButton(state, expanded: false, help: "", accessibilityLabel: "Context") {}
            }
        }
    }
}

#Preview("Context details") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            SHContextDetails(previewSplit, actions: SHContextDetailsActions())
            SHContextDetails(previewFull, actions: SHContextDetailsActions())
            SHContextDetails(SHContextDetailsModel(
                variant: .compacted, title: "Context", meta: "just compacted", total: "~23k", ofWindow: "of 200k", trailing: "estimate",
                segments: [.init(part: nil, fraction: 0.115)],
                note: "The agent reports the exact number after its next reply. Was 184k.", showsSummary: true),
                             actions: SHContextDetailsActions())
        }
    }
}

#Preview("Context details, sheet") {
    // iPad and iPhone: the details as a sheet, as wide as it is.
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            SHContextDetails(previewSplit, actions: SHContextDetailsActions(), presentation: .sheet)
            SHContextDetails(previewFull, actions: SHContextDetailsActions(), presentation: .sheet)
        }
        .frame(width: 780)
        .background(Color.sh.bgRaised)
    }
}

#Preview("Compaction, narrow") {
    // A phone's width: the rules go, then Show summary moves under the words.
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHCompactionDivider(title: "Compacted automatically", tokens: "184k → 23k", expanded: false)
            SHCompactionDivider(title: "Context overflowed · compacted and retried", tokens: "203k → 21k", tone: .warning, expanded: false)
            SHCompactionSummary(size: "2.1k", sections: [SHSummarySection(id: 0, title: "Goal", text: "Make native thread rows match the spec.")]) {}
        }
        .frame(width: 340)
    }
}

#Preview("Compaction") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHCompactionDivider(title: "Compacting context…", tokens: "184k", running: true, expanded: nil)
            SHCompactionDivider(title: "Compacted automatically", tokens: "184k → 23k", expanded: true)
            SHCompactionSummary(size: "2.1k", sections: [
                SHSummarySection(id: 0, title: "Goal", text: "Make native thread rows match the spec."),
                SHSummarySection(id: 1, title: "Files changed", text: "", files: ["ThreadView.swift", "NativePresentationTests.swift"]),
            ]) {}
            SHCompactionDivider(title: "Context overflowed · compacted and retried", tokens: "203k → 21k", tone: .warning, expanded: false)
            SHCompactionDivider(title: "Compaction stopped · nothing changed", tokens: nil, tone: .quiet, expanded: nil)
        }
        .frame(width: 640)
    }
}

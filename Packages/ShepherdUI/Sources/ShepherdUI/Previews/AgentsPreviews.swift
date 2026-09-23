import SwiftUI

private enum AgentsSamples {
    static let running = NWSubagentRun(id: "desktop", name: "desktop", role: "worker", model: "claude-fable-5-1", state: .running,
                                       detail: "edit DesktopNativeThreadView.swift", progress: 0.62, progressLabel: "Context window used")
    static let attention = NWSubagentRun(id: "ios", name: "ios", role: "worker", model: "claude-sonnet", state: .attention,
                                         detail: "waiting on your answer", waitingSince: Date().addingTimeInterval(-130),
                                         question: NWSubagentQuestion(text: "Keep MobileTokens as an alias, or migrate all 31 call sites?",
                                                                      options: ["Migrate", "Keep alias"]))
    static let done = NWSubagentRun(id: "reviewer", name: "reviewer", model: "claude-opus", state: .done,
                                    detail: "2 spec deviations fixed", detailMeta: "26 tools · 12m")
    static let failed = NWSubagentRun(id: "tests", name: "tests", role: "tester", model: "claude-sonnet", state: .failed,
                                      detail: "3 snapshot tests fail at Dynamic Type XL")
    static let paused = NWSubagentRun(id: "docs", name: "docs", role: "writer", state: .queued, stateLabel: "Paused",
                                      detail: "paused before its next model request")

    static let ledger = NWRunLedgerSummary(title: "3 subagents", state: .done, status: "all done · 45m", added: 318, removed: 64, entries: [
        NWRunLedgerEntry(id: "worker", name: "worker", state: .done, summary: "Restyled thread, sidebar, composer to the spec.", meta: "5 files · 41m"),
        NWRunLedgerEntry(id: "reviewer", name: "reviewer", state: .done, summary: "2 spec deviations found and fixed.", meta: "12m"),
        NWRunLedgerEntry(id: "tests", name: "tests", state: .done, summary: "Added 6 tests; all 14 pass on both platforms.", meta: "4m"),
    ])

    static let strip = NWRunsStripSummary(title: "12 subagents", state: .attention,
                                          cells: (Array(repeating: AgentState.done, count: 7) + [.running, .running, .running, .attention, .failed])
                                              .enumerated().map { NWRunsStripCell(id: "run-\($0.offset)", name: "lane-\($0.offset + 1)", state: $0.element) },
                                          states: "7 done · 3 running · 1 needs you · 1 failed", tokens: "3.6m tok",
                                          since: Date().addingTimeInterval(-720))
}

#Preview("Subagent cards") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.m) {
            NWSubagentCard(AgentsSamples.running, isSelected: true, inspect: {})
            NWSubagentCard(AgentsSamples.attention, inspect: {}, answer: { _ in })
            NWSubagentCard(AgentsSamples.done, inspect: {})
            NWSubagentCard(AgentsSamples.failed, inspect: {}, rerun: {})
            NWSubagentCard(AgentsSamples.paused, inspect: {})
        }
        .frame(width: 520)
    }
}

#Preview("Runs strip and ledger") {
    @Previewable @State var expanded = false
    @Previewable @State var selection: String? = "tests"
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWRunsStrip(AgentsSamples.strip, isExpanded: $expanded) { selection = $0 }
            NWRunLedger(AgentsSamples.ledger, selection: $selection)
        }
        .frame(width: 560)
    }
}

#Preview("Inspector parts") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWInspectorHeader("tests", position: "3 of 3", state: .done, meta: "claude-sonnet · 11 turns", accent: "done 11:02") {
                Button {} label: { Image(systemName: "chevron.left") }.buttonStyle(.nwIcon).accessibilityLabel("Previous subagent")
                Button {} label: { Image(systemName: "chevron.right") }.buttonStyle(.nwIcon).accessibilityLabel("Next subagent")
                Button {} label: { Image(systemName: "xmark") }.buttonStyle(.nwIcon).accessibilityLabel("Close inspector")
            }
            NWRunBrief(goal: "Cover the presentation layer on both simulators.", result: "Added 6 tests to `NativePresentationTests`; all 14 pass.")
            NWRunActions {
                Button("Re-run") {}.buttonStyle(.nw(.secondary, size: .s))
                Button {} label: { Label("Fork", systemImage: "arrow.branch") }.buttonStyle(.nw(.secondary, size: .s))
                Button("Copy transcript") {}.buttonStyle(.nw(.ghost, size: .s))
            }
        }
        .nwCard(fill: .nw.bgWindow)
        .frame(width: 460)
    }
}

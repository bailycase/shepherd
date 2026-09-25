import SwiftUI

private enum AgentsSamples {
    static let now = Date()
    static let live: [NWSubagentTrayRun] = [
        NWSubagentTrayRun(id: "worker", name: "worker", state: .running,
                          line: .working(verb: "Editing", subject: "NativeThreadPresentation.swift", live: true),
                          added: 31, removed: 4, since: now.addingTimeInterval(-37 * 60)),
        NWSubagentTrayRun(id: "reviewer", name: "reviewer", state: .attention,
                          line: .asks("Rename the new token names, or replace the old ones everywhere?"), since: now.addingTimeInterval(-130)),
        NWSubagentTrayRun(id: "tests", name: "tests", state: .done, line: .result("Added 6 presentation tests · 14 pass"),
                          added: 96, removed: 3, since: now.addingTimeInterval(-600), until: now.addingTimeInterval(-600 + 242)),
    ]
    static let liveSummary = NWSubagentTraySummary(title: "3 subagents", cells: [.running, .attention, .done], tally: [
        .init("1 needs you", state: .attention), .init("1 running", state: .running), .init("1 done"),
    ])
}

#Preview("Subagent tray") {
    @Previewable @State var collapsed = false
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWDockStack(showsTray: true, showsQueue: false) {
                NWSubagentTray(AgentsSamples.liveSummary, collapsed: collapsed, onToggle: { collapsed.toggle() }) {
                    ForEach(AgentsSamples.live) { run in
                        NWSubagentTrayRow(run, selected: run.id == "worker", actions: NWSubagentTrayActions(open: {}, answer: {}, steer: {}, stop: {}))
                    }
                }
            } queue: {
                EmptyView()
            }
            NWSubagentRecordLine(title: "Started 3 subagents", meta: "worker · reviewer · tests", action: {})
            NWSubagentRecordLine(title: "3 subagents finished", meta: "45m · 7 files · +318 −64", action: {})
        }
        .frame(width: 620)
    }
}

#Preview("Subagent question dock") {
    NWPreviewBoth {
        NWSubagentQuestionDock(name: "reviewer", question: "Rename the new token names, or replace the old ones everywhere?", options: [
            NWQuestionDockOption(number: 1, title: "Replace everywhere", detail: "Old names go; 31 call sites change.", recommended: true),
            NWQuestionDockOption(number: 2, title: "Rename the new ones", detail: "Keeps both; adds an alias."),
        ], answer: { _ in }, hide: {})
        .frame(width: 620)
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

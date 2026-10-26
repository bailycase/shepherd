import SwiftUI

private enum AgentsSamples {
    static let now = Date()
    static let live: [SHSubagentTrayRun] = [
        SHSubagentTrayRun(id: "worker", name: "worker", state: .running,
                          line: .working(verb: "Editing", subject: "NativeThreadPresentation.swift", live: true),
                          added: 31, removed: 4, since: now.addingTimeInterval(-37 * 60)),
        SHSubagentTrayRun(id: "reviewer", name: "reviewer", state: .queued,
                          line: .asked("Rename the new token names, or replace the old ones everywhere?"), since: now.addingTimeInterval(-130)),
        SHSubagentTrayRun(id: "tests", name: "tests", state: .done, line: .result("Added 6 presentation tests · 14 pass"),
                          added: 96, removed: 3, since: now.addingTimeInterval(-600), until: now.addingTimeInterval(-600 + 242)),
    ]
    static let liveSummary = SHSubagentTraySummary(title: "3 subagents", cells: [.running, .queued, .done], tally: [
        .init("1 running", state: .running), .init("1 waiting on parent"), .init("1 done"),
    ])
}

#Preview("Subagent tray") {
    @Previewable @State var collapsed = false
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHDockStack(showsTray: true, showsQueue: false) {
                SHSubagentTray(AgentsSamples.liveSummary, collapsed: collapsed, onToggle: { collapsed.toggle() }) {
                    ForEach(AgentsSamples.live) { run in
                        SHSubagentTrayRow(run, selected: run.id == "worker", actions: SHSubagentTrayActions(open: {}, steer: {}, stop: {}))
                    }
                }
            } queue: {
                EmptyView()
            }
            SHSubagentRecordLine(title: "Started 3 subagents", meta: "worker · reviewer · tests", action: {})
            SHSubagentRecordLine(title: "3 subagents finished", meta: "45m · 7 files · +318 −64", action: {})
        }
        .frame(width: 620)
    }
}

#Preview("Inspector parts") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHInspectorHeader("tests", position: "3 of 3", state: .done, meta: "claude-sonnet · 11 turns", accent: "done 11:02") {
                Button {} label: { Image(systemName: "chevron.left") }.buttonStyle(.shIcon).accessibilityLabel("Previous subagent")
                Button {} label: { Image(systemName: "chevron.right") }.buttonStyle(.shIcon).accessibilityLabel("Next subagent")
                Button {} label: { Image(systemName: "xmark") }.buttonStyle(.shIcon).accessibilityLabel("Close inspector")
            }
            SHRunBrief(goal: "Cover the presentation layer on both simulators.", result: "Added 6 tests to `NativePresentationTests`; all 14 pass.")
            SHRunActions {
                Button("Re-run") {}.buttonStyle(.sh(.secondary, size: .s))
                Button {} label: { Label("Fork", systemImage: "arrow.branch") }.buttonStyle(.sh(.secondary, size: .s))
                Button("Copy transcript") {}.buttonStyle(.sh(.ghost, size: .s))
            }
        }
        .shCard(fill: .sh.bgWindow)
        .frame(width: 460)
    }
}

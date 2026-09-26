import SwiftUI

private let previewColumns: [NWTableColumns.Column] = [.flex(2), .fixed(76), .fixed(76), .flex(1.15)]

#Preview("Page header") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWPageHeader("Automations") {
                NWPageFilterField("Filter automations", text: .constant(""))
                Button("New automation", systemImage: "plus") {}.buttonStyle(.nw(.primary))
            }
            NWPageHeader("Hosts", subtitle: "3 hosts · 1 offline", sidebar: {}) {
                Button("Add host", systemImage: "plus") {}.buttonStyle(.nw(.primary))
            }
        }
        .frame(width: 900)
    }
}

#Preview("Automation table") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWTableHead(["Automation", "Starts", "Host", "Last run"], columns: previewColumns)
            NWAutomationTableRow("Nightly migrations dry run", isOn: true, host: "build-01",
                                 outcome: NWRunOutcome("finished", state: .done, clock: .ago(Date().addingTimeInterval(-6 * 3600))),
                                 selected: true, columns: previewColumns, toggle: { _ in }, select: {})
            NWAutomationTableRow("Triage new issues", isOn: true, host: "This Mac",
                                 outcome: NWRunOutcome("asked you", state: .attention, clock: .ago(Date().addingTimeInterval(-3600))),
                                 selected: false, columns: previewColumns, toggle: { _ in }, select: {})
            NWAutomationTableRow("Weekly dependency bumps", isOn: true, host: "This Mac",
                                 outcome: NWRunOutcome("running", state: .running, clock: .elapsed(since: Date().addingTimeInterval(-240))),
                                 selected: false, columns: previewColumns, toggle: { _ in }, select: {})
            NWAutomationTableRow("Stale branch cleanup", isOn: false, switchEnabled: false, host: "horizon",
                                 outcome: NWRunOutcome("host offline"), selected: false, columns: previewColumns,
                                 toggle: nil, select: {})
        }
        .frame(width: 820)
    }
}

#Preview("Automation detail parts") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWPageSectionLabel("Prompt")
            NWPageQuote("Run every pending migration against a copy of prod in a throwaway database. Report anything irreversible or slower than 30s.")
            NWPageFact("When", value: "When Shepherd starts", mono: false, labelWidth: 90, style: .detail)
            NWPageFact("Host", value: "build-01", labelWidth: 90, style: .detail)
            NWPageSectionLabel("Recent runs")
            VStack(spacing: 0) {
                NWAutomationRunLine(started: "Sep 24 02:00", word: "finished", state: .done, duration: "4m", open: {})
                NWAutomationRunLine(started: "Sep 22 02:00", word: "interrupted", state: .failed, duration: "11m")
                NWAutomationRunLine(started: "Sep 21 02:00", word: "stopped", state: nil, duration: "3m")
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

#Preview("Host page cards") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NWPageMetrics.columnGap) {
            NWHostPageCard(name: "This Mac", subtitle: "Shepherd app · agent 0.8.2", status: "Connected", state: .done,
                           facts: [.init("Running", "2 threads"), .init("Worktrees", "11"), .init("Repos", "shepherd, dashboard-web")])
            NWHostPageCard(name: "horizon", subtitle: "Shepherd app", offlineSince: Date().addingTimeInterval(-3 * 3600),
                           status: "Unreachable", state: .failed,
                           facts: [.init("Waiting", "2 threads, 1 automation"), .init("Last seen", "Sep 24 07:12"),
                                   .init("Address", "horizon.local:7040")]) {
                Button("Retry", systemImage: "arrow.clockwise") {}.buttonStyle(.nw(.secondary, size: .s))
                Button("Remove") {}.buttonStyle(.nw(.ghost, size: .s))
            }
        }
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
    }
}

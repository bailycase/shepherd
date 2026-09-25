import SwiftUI

#Preview("Automation rows") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWListHeader("Running now")
            NWListCard {
                NWAutomationRow("Merge PR #24 after CI", when: "When Shepherd starts · Shepherd", status: "Running",
                                statusTone: .running, clock: .elapsed(since: Date().addingTimeInterval(-250)), leading: .running,
                                isOn: true, chevron: true, toggle: { _ in }, open: {})
            }
            NWListHeader("All", count: 4)
            NWListCard {
                NWAutomationRow("Nightly migrations dry run", when: "When Shepherd starts · orders-svc", status: "Finished",
                                statusTone: .done, clock: .ago(Date().addingTimeInterval(-43_000)), leading: .symbol("bolt"),
                                isOn: true, toggle: { _ in }, open: {})
                NWAutomationRow("Triage new Sentry issues", when: "When Shepherd starts · checkout-svc", status: "Asked you",
                                statusTone: .attention, leading: .symbol("bolt", .attention), isOn: true, selected: true,
                                toggle: { _ in }, open: {})
                NWAutomationRow("Stale branch cleanup", when: "By hand · horizon", status: "Host offline", leading: .symbol("bolt"),
                                isOn: false, switchEnabled: false, dimmed: true)
            }
        }
        .frame(width: 380)
    }
}

#Preview("Automation detail parts") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            VStack(spacing: 0) {
                NWFactRow("When", value: "When Shepherd starts")
                NWFactRow("Runs on", value: "build-01 · a new thread each run", mono: true)
                NWFactRow("Folder", value: "/Users/dev/orders-svc", mono: true)
            }
            NWAutomationPrompt("Run every pending migration against a copy of prod in a throwaway database. Report anything irreversible or slower than 30s.")
            NWRunBars([0.3, 0.32, 0.3, 0.34, 1, 0.3, 0.28, 0.33, 0.3, 0.5, 0.3, 0.29, 0.32, 0.31].enumerated().map { index, height in
                NWRunBars.Bar(id: "\(index)", height: height, state: index == 4 ? .failed : index == 9 ? .attention : .done,
                              label: "run \(index)")
            }, first: "Sep 11 02:00", summary: "interrupted: 1 · asked: 1", last: "Sep 24 02:00")
            VStack(spacing: 0) {
                NWRunRow(started: "Sep 24 02:00", word: "finished", state: .done, duration: "43s", open: {})
                NWRunRow(started: "Sep 23 02:00", word: "stopped", state: .idle, duration: "11m")
                NWRunRow(started: "Sep 22 02:00", word: "interrupted", state: .failed, duration: "3m")
            }
        }
        .frame(width: 440)
    }
}

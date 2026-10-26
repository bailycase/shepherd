import SwiftUI

private let shPreviewGoalText = "Ledger tests pass and go vet is clean, without changing the consumer package."

private struct SHPreviewGoal: View {
    let state: SHGoalState
    var size: SHGoalSize = .desktop
    var framed = true

    private var meta: String {
        switch state {
        case .working: "71k tokens"
        case .checking: "running go test and go vet"
        case .met: "104k tokens · 41 tests passed"
        case .paused: "paused by you · the clock stops"
        case .needsYou: "the same test failed 3 times in a row"
        }
    }

    var body: some View {
        SHGoalCard(state: state, time: state == .met ? "9m 12s" : "6m 40s", meta: meta,
                   text: shPreviewGoalText, size: size, framed: framed,
                   pause: {}, resume: {}, edit: {}, clear: {})
    }
}

#Preview("Goal · desktop states") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            ForEach(SHGoalState.allCases, id: \.self) { state in
                SHPreviewGoal(state: state)
            }
            SHGoalHeaderPill(time: "6m 40s")
        }
        .frame(width: 620)
        .environment(\.shMotionPaused, true)
    }
}

#Preview("Goal · touch states") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHPreviewGoal(state: .working, size: .touch)
            SHPreviewGoal(state: .needsYou, size: .touch)
        }
        .frame(width: 366)
        .environment(\.shMotionPaused, true)
    }
}

#Preview("Goal · shared dock") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHPreviewGoal(state: .working, framed: false)
            SHHairline()
            SHQueueStack(count: 1, collapsed: false, framed: false, onToggle: {}) {
                SHQueueRow("Use table-driven tests, like ledger_test.go.", kind: .queued(number: 1))
            } options: {}
        }
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SHGoalMetrics.desktopRadius))
        .shBorder(Color.sh.lineStrong, radius: SHGoalMetrics.desktopRadius)
        .frame(width: 620)
        .environment(\.shMotionPaused, true)
    }
}

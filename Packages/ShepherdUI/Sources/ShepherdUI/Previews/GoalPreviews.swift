import SwiftUI

private let nwPreviewGoalText = "Ledger tests pass and go vet is clean, without changing the consumer package."

private struct NWPreviewGoal: View {
    let state: NWGoalState
    var size: NWGoalSize = .desktop
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
        NWGoalCard(state: state, time: state == .met ? "9m 12s" : "6m 40s", meta: meta,
                   text: nwPreviewGoalText, size: size, framed: framed,
                   pause: {}, resume: {}, edit: {}, clear: {})
    }
}

#Preview("Goal · desktop states") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            ForEach(NWGoalState.allCases, id: \.self) { state in
                NWPreviewGoal(state: state)
            }
            NWGoalHeaderPill(time: "6m 40s")
        }
        .frame(width: 620)
        .environment(\.nwMotionPaused, true)
    }
}

#Preview("Goal · touch states") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWPreviewGoal(state: .working, size: .touch)
            NWPreviewGoal(state: .needsYou, size: .touch)
        }
        .frame(width: 366)
        .environment(\.nwMotionPaused, true)
    }
}

#Preview("Goal · shared dock") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWPreviewGoal(state: .working, framed: false)
            NWHairline()
            NWQueueStack(count: 1, collapsed: false, framed: false, onToggle: {}) {
                NWQueueRow("Use table-driven tests, like ledger_test.go.", kind: .queued(number: 1))
            } options: {}
        }
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NWGoalMetrics.desktopRadius))
        .nwBorder(Color.nw.lineStrong, radius: NWGoalMetrics.desktopRadius)
        .frame(width: 620)
        .environment(\.nwMotionPaused, true)
    }
}

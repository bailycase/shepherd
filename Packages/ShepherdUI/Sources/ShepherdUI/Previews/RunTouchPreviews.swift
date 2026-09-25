import SwiftUI

private enum RunTouchSamples {
    static let now = Date()

    static let worker = NWRunCardValue(id: "worker", name: "worker", tags: "background · fable-5-1", state: .running,
                                       detail: "edit Sources/ShepherdRemote/NativeThreadPresentation.swift", step: "step 1 of 3",
                                       progress: 0.34, progressLabel: "Context window used", tokens: "922k",
                                       since: now.addingTimeInterval(-37 * 60))
    static let reviewer = NWRunCardValue(id: "reviewer", name: "reviewer", tags: "async · opus", state: .attention,
                                         detail: "waiting on your answer",
                                         question: "Two token names collide with existing `Tokens.textSecondary`. Rename the new ones, or replace the old ones everywhere?",
                                         options: ["Replace everywhere", "Rename new ones"], since: now.addingTimeInterval(-300),
                                         waitingSince: now.addingTimeInterval(-120))
    static let tests = NWRunCardValue(id: "tests", name: "tests", tags: "async · sonnet", state: .done,
                                      detail: "Added 6 presentation tests · all 14 pass", since: now.addingTimeInterval(-600),
                                      until: now.addingTimeInterval(-358), added: 96, removed: 3)
    static let failed = NWRunCardValue(id: "docs", name: "docs", tags: "writer", state: .failed,
                                       detail: "exit 1 · context limit reached after 41 turns")
    static let paused = NWRunCardValue(id: "lint", name: "lint", state: .queued, stateLabel: "Paused",
                                       detail: "paused before its next model request")

    static let history = [
        NWRunHistoryRow(id: "a", name: "claude-header-path", state: .done, summary: "Fix agent model selection",
                        finishedAt: now.addingTimeInterval(-3600), added: 12, removed: 4),
        NWRunHistoryRow(id: "b", name: "spec-audit", state: .done, summary: "Listed 11 spec gaps", finishedAt: now.addingTimeInterval(-7200)),
    ]
}

#Preview("Run cards (touch)") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.m) {
            NWRunCard(RunTouchSamples.worker, open: {})
            NWRunCard(RunTouchSamples.reviewer, open: {}, answer: { _ in })
            NWRunCard(RunTouchSamples.tests, isSelected: true, open: {})
            NWRunCard(RunTouchSamples.failed, open: {}, rerun: {})
            NWRunCard(RunTouchSamples.paused, open: {})
        }
        .frame(width: 360)
    }
}

#Preview("Run history (touch)") {
    NWPreviewBoth {
        NWRunHistoryList(RunTouchSamples.history) { _ in }
            .frame(width: 360)
    }
}

#Preview("Run brief, header and steer (touch)") {
    @Previewable @State var draft = ""
    @Previewable @State var tab = "reviewer"
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWRunTabs(selection: $tab, tabs: [("worker", "worker"), ("reviewer", "reviewer"), ("tests", "tests")])
            NWRunHeader("tests", position: "3 of 3", state: .done, meta: "claude-sonnet · 11 turns", accent: "done 11:02") {
                Button {} label: { Image(systemName: "xmark") }.buttonStyle(.nwIcon).accessibilityLabel("Close")
            }
            NWRunGoal(goal: "Restyle the desktop native thread view and the iOS app to match the spec.", note: "step 1 of 3 · 62%")
            NWRunGoal(goal: "Cover the presentation layer.", label: "Goal", result: "Added 6 tests; all 14 pass on macOS and iPadOS.")
            NWSteerField(text: $draft, prompt: "Steer worker…", caption: "to: worker · not the parent · lands before its next turn") {}
        }
        .frame(width: 360)
    }
}

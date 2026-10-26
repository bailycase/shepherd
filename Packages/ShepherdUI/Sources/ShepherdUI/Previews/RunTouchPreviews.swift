import SwiftUI

private enum RunTouchSamples {
    static let now = Date()

    static let worker = SHRunCardValue(id: "worker", name: "worker", tags: "background · fable-5-1", state: .running,
                                       detail: "edit Sources/ShepherdRemote/NativeThreadPresentation.swift", step: "step 1 of 3",
                                       progress: 0.34, progressLabel: "Context window used", tokens: "922k",
                                       since: now.addingTimeInterval(-37 * 60))
    static let reviewer = SHRunCardValue(id: "reviewer", name: "reviewer", tags: "async · opus", state: .queued,
                                         stateLabel: "Waiting on parent", detail: "waiting on its parent's answer",
                                         question: "Two token names collide with existing `Tokens.textSecondary`. Rename the new ones, or replace the old ones everywhere?",
                                         options: ["Replace everywhere", "Rename new ones"], since: now.addingTimeInterval(-300),
                                         waitingSince: now.addingTimeInterval(-120))
    static let tests = SHRunCardValue(id: "tests", name: "tests", tags: "async · sonnet", state: .done,
                                      detail: "Added 6 presentation tests · all 14 pass", since: now.addingTimeInterval(-600),
                                      until: now.addingTimeInterval(-358), added: 96, removed: 3)
    static let failed = SHRunCardValue(id: "docs", name: "docs", tags: "writer", state: .failed,
                                       detail: "exit 1 · context limit reached after 41 turns")
    static let paused = SHRunCardValue(id: "lint", name: "lint", state: .queued, stateLabel: "Paused",
                                       detail: "paused before its next model request")

    static let history = [
        SHRunHistoryRow(id: "a", name: "claude-header-path", state: .done, summary: "Fix agent model selection",
                        finishedAt: now.addingTimeInterval(-3600), added: 12, removed: 4),
        SHRunHistoryRow(id: "b", name: "spec-audit", state: .done, summary: "Listed 11 spec gaps", finishedAt: now.addingTimeInterval(-7200)),
    ]
}

#Preview("Run cards (touch)") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.m) {
            SHRunCard(RunTouchSamples.worker, open: {})
            SHRunCard(RunTouchSamples.reviewer, open: {})
            SHRunCard(RunTouchSamples.tests, isSelected: true, open: {})
            SHRunCard(RunTouchSamples.failed, open: {}, rerun: {})
            SHRunCard(RunTouchSamples.paused, open: {})
        }
        .frame(width: 360)
    }
}

#Preview("Run history (touch)") {
    SHPreviewBoth {
        SHRunHistoryList(RunTouchSamples.history) { _ in }
            .frame(width: 360)
    }
}

#Preview("Run brief, header and steer (touch)") {
    @Previewable @State var draft = ""
    @Previewable @State var tab = "reviewer"
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHRunTabs(selection: $tab, tabs: [("worker", "worker"), ("reviewer", "reviewer"), ("tests", "tests")])
            SHRunHeader("tests", position: "3 of 3", state: .done, meta: "claude-sonnet · 11 turns", accent: "done 11:02") {
                Button {} label: { Image(systemName: "xmark") }.buttonStyle(.shIcon).accessibilityLabel("Close")
            }
            SHRunGoal(goal: "Restyle the desktop native thread view and the iOS app to match the spec.", note: "step 1 of 3 · 62%")
            SHRunGoal(goal: "Cover the presentation layer.", label: "Goal", result: "Added 6 tests; all 14 pass on macOS and iPadOS.")
            SHSteerField(text: $draft, prompt: "Steer worker…", caption: "to: worker · not the parent · lands before its next turn") {}
        }
        .frame(width: 360)
    }
}

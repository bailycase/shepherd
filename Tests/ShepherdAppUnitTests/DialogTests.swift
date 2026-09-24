import Testing
import ShepherdUI
@testable import ShepherdApp

/// Sheets and dialogs: how checklist rows read, and stable footer actions.
@Suite("Dialogs")
struct DialogTests {
    @Test(arguments: [
        (WorktreeCheckState.pending, AgentState.queued, "Pending", ""),
        (.checking, .running, "Checking", ""),
        (.pass("git version 2.54.0"), .done, "Passed", "git version 2.54.0"),
        (.fail("no origin"), .failed, "Failed", "no origin"),
    ])
    func prerequisiteChecksReadAsChecklistRows(check: WorktreeCheckState, state: AgentState, word: String, detail: String) {
        #expect(check.checklist == ChecklistStatus(state: state, word: word, detail: detail))
    }

    @Test(arguments: [
        (WorktreeFinalizer.StepState.pending, AgentState.queued, "Pending", ""),
        (.running, .running, "Running", ""),
        (.done("2 files"), .done, "Done", "2 files"),
        (.skipped("nothing to commit"), .idle, "Skipped", "nothing to commit"),
        (.failed("push rejected"), .failed, "Failed", "push rejected"),
    ])
    func pipelineStepsReadAsChecklistRows(step: WorktreeFinalizer.StepState, state: AgentState, word: String, detail: String) {
        #expect(step.checklist == ChecklistStatus(state: state, word: word, detail: detail))
    }

    /// Recommended repo settings are informational: none of them may look like a failure that
    /// blocks Finalize.
    @Test(arguments: [WorktreeRepoSettingState.unknown, .checking, .enabled, .disabled, .unavailable("needs gh access")])
    func repoSettingsNeverReadAsFailures(setting: WorktreeRepoSettingState) {
        #expect(setting.checklist.state != .failed)
        #expect(setting.checklist.state != .attention)
    }

    @Test func anUnreachableRepoSettingExplainsWhy() {
        #expect(WorktreeRepoSettingState.unavailable("needs gh access").checklist.detail == "needs gh access")
    }

    /// A fresh identity per render rebuilds every footer button; the label is stable.
    @Test func dialogActionsKeepTheirIdentityAcrossRenders() {
        let first = DialogAction("Delete agent only") {}
        let second = DialogAction("Delete agent only", kind: .destructive) {}
        #expect(first.id == second.id)
        #expect(DialogAction("Cancel", kind: .cancel) {}.id != first.id)
    }
}

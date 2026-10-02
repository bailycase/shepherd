import Testing
import ShepherdSessions
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

    /// An agent's call waiting for the user: Deny is the ⎋ cancel, each Allow answers as it says, and
    /// neither is the ⏎ default (a Return typed as the dialog appears allows nothing) or destructive.
    @MainActor @Test func theApprovalDialogsButtonsAnswerAsTheySayAndNoneIsTheDefault() {
        var answers: [AgentApprovalDecision] = []
        let actions = PeerApprovalDialog.actions { answers.append($0) }

        let labels = actions.map { $0.label }
        let kinds = actions.map { $0.kind }
        let enabled = actions.allSatisfy { $0.isEnabled }
        #expect(labels == ["Deny", "Allow for this thread", "Allow once"])
        #expect(kinds == [.cancel, .normal, .normal])
        #expect(enabled)
        for action in actions { action.action() }
        #expect(answers == [.deny, .allowForThread, .allowOnce])
    }

    /// A fresh identity per render rebuilds every footer button; the label is stable.
    @Test func dialogActionsKeepTheirIdentityAcrossRenders() {
        let first = DialogAction("Delete agent only") {}
        let second = DialogAction("Delete agent only", kind: .destructive) {}
        #expect(first.id == second.id)
        #expect(DialogAction("Cancel", kind: .cancel) {}.id != first.id)
    }
}

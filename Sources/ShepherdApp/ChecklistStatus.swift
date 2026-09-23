import ShepherdUI

/// How a row of a sheet's checklist reads (Finalize's prerequisite checks, its pipeline, the
/// recommended repo settings): the state glyph, the word VoiceOver says, and the trailing detail.
struct ChecklistStatus: Equatable {
    let state: AgentState
    let word: String
    let detail: String
}

extension WorktreeCheckState {
    /// A prerequisite check: a failure blocks Finalize.
    var checklist: ChecklistStatus {
        switch self {
        case .pending: ChecklistStatus(state: .queued, word: "Pending", detail: "")
        case .checking: ChecklistStatus(state: .running, word: "Checking", detail: "")
        case .pass(let detail): ChecklistStatus(state: .done, word: "Passed", detail: detail)
        case .fail(let detail): ChecklistStatus(state: .failed, word: "Failed", detail: detail)
        }
    }
}

extension WorktreeFinalizer.StepState {
    /// A pipeline step: a skipped step is quiet, not a failure.
    var checklist: ChecklistStatus {
        switch self {
        case .pending: ChecklistStatus(state: .queued, word: "Pending", detail: "")
        case .running: ChecklistStatus(state: .running, word: "Running", detail: "")
        case .done(let detail): ChecklistStatus(state: .done, word: "Done", detail: detail)
        case .skipped(let detail): ChecklistStatus(state: .idle, word: "Skipped", detail: detail)
        case .failed(let detail): ChecklistStatus(state: .failed, word: "Failed", detail: detail)
        }
    }
}

extension WorktreeRepoSettingState {
    /// A recommended GitHub setting. Informational: off never blocks Finalize, so it reads as
    /// idle, never failed.
    var checklist: ChecklistStatus {
        switch self {
        case .unknown: ChecklistStatus(state: .queued, word: "Unknown", detail: "")
        case .checking: ChecklistStatus(state: .running, word: "Checking", detail: "")
        case .enabled: ChecklistStatus(state: .done, word: "On", detail: "on")
        case .disabled: ChecklistStatus(state: .idle, word: "Off", detail: "off")
        case .unavailable(let reason): ChecklistStatus(state: .idle, word: "Unavailable", detail: reason)
        }
    }
}

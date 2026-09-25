import ShepherdCore
import ShepherdRemote
import ShepherdUI

// The app's lifecycles projected onto Night Watch's one status enum, which drives every pill,
// dot, glyph, and strip.
extension AgentState {
    /// An agent's reported status: working runs, blocked needs you.
    init(_ status: AgentStatus) {
        switch status {
        case .working: self = .running
        case .blocked: self = .attention
        case .done: self = .done
        case .idle: self = .idle
        }
    }

    /// A subagent run.
    init(_ state: NativeSubagentState) {
        switch state {
        case .running: self = .running
        case .needsYou: self = .attention
        case .done: self = .done
        case .failed: self = .failed
        }
    }

    /// How an automation or one of its runs reads: stopped is quiet, interrupted failed.
    init(_ tone: AutomationTone) {
        switch tone {
        case .running: self = .running
        case .attention: self = .attention
        case .done: self = .done
        case .failed: self = .failed
        case .stopped, .off: self = .idle
        }
    }

    /// A tool call.
    init(_ state: NativeToolRow.State) {
        switch state {
        case .running: self = .running
        case .done: self = .done
        case .failed: self = .failed
        }
    }
}

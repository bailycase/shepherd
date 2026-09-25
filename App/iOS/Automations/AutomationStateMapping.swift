import ShepherdRemote
import ShepherdUI

extension AgentState {
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
}

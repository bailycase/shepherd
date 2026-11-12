import Observation
import ShepherdCore

/// What one local agent shows that changes with a turn: its status and its sparkline's samples
/// (`ShepherdViewModel.agentLive`). One box per agent for the agent's life, compared by identity and
/// written only when a value changes, so a view that reads it reruns for that agent's change and no
/// other. The sidebar's row reads the samples; the folded terminal line reads the status
/// (`LocalFoldedThreadChrome`). Nothing in the shell around a layout does: it reads
/// `ShepherdViewModel.workspaceStructure`.
@MainActor @Observable
final class AgentLive {
    private(set) var status: AgentStatus
    var samples: [Double] = []

    init(status: AgentStatus) {
        self.status = status
    }

    /// The agent's status as the host last said it. Returns the status it held.
    @discardableResult
    func report(_ status: AgentStatus) -> AgentStatus {
        let old = self.status
        if old != status { self.status = status }
        return old
    }
}

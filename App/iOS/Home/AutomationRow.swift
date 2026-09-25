import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// An automation run as Home's overview lists it (iPadOverview's Running now): read-only here;
/// the Automations screen (automations track) is where they are managed.
struct AutomationRow: View, Equatable {
    let row: FleetAutomationRow

    var body: some View {
        NWListRow(row.name, subtitle: "\(row.stateWord) · \(row.place)", subtitleTone: tone,
                  leading: row.run == nil ? .symbol("bolt") : .state(state), trailing: row.hostTag.map { .host($0) } ?? .none,
                  chevron: row.run != nil, dimmed: row.offline || !row.enabled)
            .accessibilityHint(row.run == nil ? "" : "Opens its run")
    }

    private var state: AgentState {
        guard let status = row.runStatus else { return .idle }
        return status == .idle ? .done : AgentState(status)
    }

    private var tone: AgentState? {
        switch row.runStatus {
        case .blocked: .attention
        case .working: .running
        default: nil
        }
    }
}

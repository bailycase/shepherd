import SwiftUI
import ShepherdUI
import ShepherdRemote

/// A triggered automation's run threads folded under one row, as the Mac's Spaces mode folds them
/// (`FleetRunGroup`): the name, how many, the unread count, a dot while one runs or waits on you,
/// and "paused". The row opens or closes the group (closed to start); open, its runs follow,
/// indented under the glyph, each opening its thread and clearing its unread dot.
struct RunGroupSection: View {
    let group: FleetRunGroup
    let selected: AgentRef?
    /// The iPad sidebar's one-line rows; Home's card rows otherwise.
    var compact = false
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        VStack(spacing: 0) {
            let toggle = { SidebarThreads.of(hosts).toggleRunGroup(group.key) }
            SHAutomationGroupRow(group.hostTag.map { "\(group.name) · \($0)" } ?? group.name, count: group.count,
                                 unread: group.unread, expanded: group.expanded, rollup: Self.rollup(group.rollup),
                                 paused: group.paused, toggle: toggle)
                // The Mac's row is 28pt; a touch needs 44 (the row's own tap covers its middle).
                .frame(minHeight: SH.Height.touch)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
            if group.expanded {
                ForEach(group.rows) { row in
                    Button { open(row) } label: {
                        ThreadRow(row: row, selected: row.ref.agentRef == selected, compact: compact)
                            .equatable()
                            .clipShape(RoundedRectangle(cornerRadius: compact ? SH.Radius.m : 0))
                    }
                    .buttonStyle(.shRow(radius: compact ? SH.Radius.m : 0))
                    .padding(.leading, SHProjectMetrics.chevronSlot + SHProjectMetrics.gap)
                    .contextMenu { ThreadRowMenu(thread: row.ref.agentRef) }
                }
            }
        }
    }

    private func open(_ row: FleetThreadRow) {
        AutomationsStore.of(hosts).markRead(thread: row.ref)
        navigator.open(.thread(row.ref.agentRef))
    }

    static func rollup(_ rollup: FleetRunGroup.Rollup) -> SHAutomationGroupRow.Rollup {
        switch rollup {
        case .quiet: .quiet
        case .running: .running
        case .waiting: .waiting
        }
    }
}

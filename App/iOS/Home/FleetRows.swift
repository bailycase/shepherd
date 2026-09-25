import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// One host's agents as Home and the sidebar list them: plain values, derived from the hosts'
/// pushed state (the home track moves this into a store that derives once per change).
struct FleetSection: Identifiable, Equatable {
    struct Row: Identifiable, Equatable {
        var ref: AgentRef
        var title: String
        var state: AgentState
        /// "Running · Shepherd": the state word and the agent's space.
        var detail: String

        var id: AgentRef { ref }
    }

    var id: UUID
    var name: String
    var phase: RemoteHostPhase
    var rows: [Row]

    @MainActor static func sections(_ hosts: MobileHosts) -> [FleetSection] {
        hosts.hosts.map { host in
            let spaces = Dictionary(host.state.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return FleetSection(id: host.id, name: host.name, phase: host.phase, rows: host.state.agents.map { agent in
                let state = AgentState(agent.status)
                return Row(ref: AgentRef(host: host.id, agent: agent.id), title: agent.name, state: state,
                           detail: [state.label, spaces[agent.spaceID]].compactMap { $0 }.joined(separator: " · "))
            })
        }
    }
}

/// An agent row: the status dot, the title over its status line, 56pt tall.
struct FleetRowView: View, Equatable {
    let row: FleetSection.Row
    var selected = false
    var dimmed = false

    var body: some View {
        HStack(spacing: NW.Space.l) {
            NWStatusDot(row.state, size: MobileLayout.statusDot)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(row.title).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                Text(row.detail).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: MobileLayout.twoLineRowHeight)
        .background(selected ? Color.nw.bgSelected : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A host's header: its name and connection word, and Retry while it is offline.
struct FleetHostHeader: View {
    let section: FleetSection
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        HStack(spacing: NW.Space.m) {
            Text(section.name).nwSectionLabel().lineLimit(1)
            Spacer(minLength: 0)
            NWStatusPill(section.phase.isConnected ? .done : section.phase == .connecting ? .running : .failed,
                         label: section.phase.word)
            if !section.phase.isConnected, section.phase != .connecting {
                Button("Retry") { hosts.retry(section.id) }.buttonStyle(.nw(.ghost, size: .s))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

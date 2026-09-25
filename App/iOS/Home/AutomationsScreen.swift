import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// Automations on every host (MobileAutomations board, read-only; home track): the ones running
/// now, then all of them with how their run is doing. A run opens as its thread; saving,
/// switching and running automations stays on the Mac in this release.
struct AutomationsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                if model.automations.isEmpty {
                    NWEmptyState(Text("No automations"), message: "Automations saved in Shepherd on a Mac show here with their runs.") {
                        EmptyView()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, MobileLayout.sectionSpacing)
                } else {
                    AutomationSections(count: model.automations.count, running: model.automationsRunning, quiet: model.automationsQuiet)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .refreshable { await feed.refresh() }
        .task { await feed.watch() }
        .navigationTitle("Automations")
    }
}

private struct AutomationSections: View {
    let count: Int
    let running: [FleetAutomationRow]
    let quiet: [FleetAutomationRow]

    var body: some View {
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                NWListHeader("Running now")
                NWListCard {
                    ForEach(running) { row in AutomationRowButton(row: row) }
                }
            }
        }
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            if !quiet.isEmpty {
                NWListHeader("All", count: count)
                NWListCard {
                    ForEach(quiet) { row in AutomationRowButton(row: row) }
                }
            }
            Text("Automations are saved, switched on and run from Shepherd on the Mac.")
                .nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                .padding(.horizontal, NW.Space.xs)
                .padding(.top, NW.Space.xs)
        }
    }
}

/// One automation: opens its run's thread while it has one.
private struct AutomationRowButton: View {
    let row: FleetAutomationRow
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if let run = row.run {
            Button { navigator.open(.thread(run.agentRef)) } label: { AutomationRow(row: row).equatable() }
                .buttonStyle(.nwRow(radius: 0))
        } else {
            AutomationRow(row: row).equatable()
        }
    }
}

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

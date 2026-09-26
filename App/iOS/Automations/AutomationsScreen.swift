import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Automations on every host (MobileAutomations, iPadAutomations boards; automations track):
/// the ones running now, then all of them, each with its switch. iPhone opens one on its own
/// screen; iPad lists them beside the chosen one's detail. `+` saves a new one on a host that
/// takes it. A host from before automations over the remote protocol shows its own read-only.
///
/// The Home destination `.home(.automations)` shows this screen (the hook `AutomationsScreen()`).
struct AutomationsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let store = AutomationsStore.of(hosts)
        let model = store.model
        Group {
            if model.rows.isEmpty {
                NWEmptyState(Text("No automations"),
                             message: "An automation is a saved prompt a host runs as a new thread. Save one here, or ask an agent on the Mac to.") {
                    if !store.editableHosts.isEmpty {
                        Button("New automation", systemImage: "plus") { AutomationsHooks.create(navigator: navigator) }
                            .buttonStyle(.nw(.primary))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sizeClass == .regular {
                AutomationsSplit(store: store, model: model)
            } else {
                ScrollView {
                    AutomationsList(store: store, model: model, chosen: nil) { key in AutomationsHooks.open(key, navigator: navigator) }
                        .padding(.horizontal, MobileLayout.gutter)
                        .padding(.bottom, MobileLayout.sectionSpacing)
                }
                .refreshable { await store.refreshRuns() }
            }
        }
        .background(Color.nw.bgWindow)
        .task { await store.watch() }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            if !store.editableHosts.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { AutomationsHooks.create(navigator: navigator) } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New automation")
                }
            }
        }
    }
}

/// The list: a failure's banner, Running now, All, and why a host's automations are read-only.
private struct AutomationsList: View {
    let store: AutomationsStore
    let model: AutomationsModel
    /// The row the iPad shows beside the list.
    let chosen: AutomationKey?
    let open: (AutomationKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
            if let failure = store.failure {
                NWBanner(.failed, title: failure.message) {
                    Button("OK") { store.failure = nil }.buttonStyle(.nw(.secondary))
                }
            }
            if !model.live.isEmpty {
                if chosen == nil {
                    // iPhone (MobileAutomations): each live run is its own card.
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        NWListHeader("Running now")
                        VStack(spacing: MobileLayout.blockSpacing) {
                            ForEach(model.live) { row in
                                AutomationRunCardView(row: row) { open(row.key) }.equatable()
                            }
                        }
                    }
                } else {
                    section("Running now", count: nil, rows: model.live)
                }
            }
            if !model.quiet.isEmpty {
                section("All", count: model.rows.count, rows: model.quiet)
            }
            if !store.readOnlyNotes.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    ForEach(store.readOnlyNotes, id: \.self) { note in
                        Text(note).nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                    }
                }
                .padding(.horizontal, NW.Space.xs)
            }
        }
    }

    private func section(_ title: String, count: Int?, rows: [AutomationListRow]) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            NWListHeader(title, count: count)
            NWListCard {
                ForEach(rows) { row in
                    AutomationListRowView(row: row, isOn: store.isOn(row), busy: store.busy.contains(row.key),
                                          selected: row.key == chosen, chevron: false,
                                          toggle: { store.setEnabled(row.key, $0) }, open: { open(row.key) })
                        .equatable()
                }
            }
        }
    }
}

/// One automation as a list row (MobileAutomations): its switch flips it without opening it.
struct AutomationListRowView: View, Equatable {
    let row: AutomationListRow
    let isOn: Bool
    let busy: Bool
    let selected: Bool
    let chevron: Bool
    let toggle: (Bool) -> Void
    let open: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.isOn == b.isOn && a.busy == b.busy && a.selected == b.selected && a.chevron == b.chevron
    }

    var body: some View {
        let state = AgentState(row.tone)
        NWAutomationRow(row.name, when: [row.when, row.hostTag ?? row.place].joined(separator: " · "), status: row.status,
                        statusTone: row.tone == .stopped || row.tone == .off ? nil : state, clock: clock,
                        leading: row.tone == .running ? .running : .symbol("bolt", row.tone == .attention ? .attention : nil),
                        // Read-only (offline, or an older host): the "when" line says whether it is on.
                        isOn: row.abilities.toggle ? isOn : nil, switchEnabled: !busy, selected: selected,
                        dimmed: row.offline || !isOn, chevron: chevron, toggle: toggle, open: open)
    }

    private var clock: NWRowClock? {
        switch row.clock {
        case .elapsed(let since)?: .elapsed(since: since)
        case .ago(let at)?: .ago(at)
        case nil: nil
        }
    }
}

/// A live run as Running now's card on iPhone (MobileAutomations): a tap opens the automation.
struct AutomationRunCardView: View, Equatable {
    let row: AutomationListRow
    let open: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.row == b.row }

    var body: some View {
        let since: Date? = if case .elapsed(let start)? = row.clock { start } else { nil }
        NWAutomationRunCard(row.name, host: row.hostTag ?? row.hostName, status: row.status, asking: row.tone == .attention,
                            since: since, open: open)
    }
}

/// iPad: the list beside the chosen automation's detail.
private struct AutomationsSplit: View {
    let store: AutomationsStore
    let model: AutomationsModel

    var body: some View {
        let current = model.rows.first { $0.key == store.chosen }?.key ?? model.rows[0].key
        HStack(spacing: 0) {
            ScrollView {
                AutomationsList(store: store, model: model, chosen: current) { store.chosen = $0 }
                    .padding(MobileLayout.gutter)
            }
            .refreshable { await store.refreshRuns() }
            .frame(width: MobileLayout.automationsListWidth)
            NWHairline(.vertical)
            AutomationDetailContent(key: current, pad: true)
                .frame(maxWidth: .infinity)
        }
    }
}

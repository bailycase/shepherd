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
                SHEmptyState(Text("No automations"),
                             message: "An automation is a saved prompt a host runs as a new thread. Save one here, or ask an agent on the Mac to.") {
                    if !store.editableHosts.isEmpty {
                        Button("New automation", systemImage: "plus") { AutomationsHooks.create(navigator: navigator) }
                            .buttonStyle(.sh(.primary))
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
                .refreshable { await store.refresh() }
            }
        }
        .background(Color.sh.bgWindow)
        .task { await store.watch() }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar(removing: sizeClass == .regular ? .title : nil)
        .toolbar {
            // iPadAutomations: "Automations" leads the bar, over the list.
            if sizeClass == .regular {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Automations").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if !store.editableHosts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    // New automation is the lantern circle (MobileAutomations).
                    Button("New automation", systemImage: "plus") { AutomationsHooks.create(navigator: navigator) }
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.lantern)
                }
            }
        }
    }
}

/// The list: a failure's banner, Running now and All (on iPad one flat list), and why a host's
/// automations are read-only.
private struct AutomationsList: View {
    let store: AutomationsStore
    let model: AutomationsModel
    /// The row the iPad shows beside the list.
    let chosen: AutomationKey?
    let open: (AutomationKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
            if let failure = store.failure {
                SHBanner(.failed, title: failure.message) {
                    Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
                }
            }
            if chosen != nil {
                // iPad (iPadAutomations): one flat list, the live runs first, the chosen row filled.
                VStack(spacing: SH.Space.xxs) {
                    ForEach(model.live + model.quiet) { row in padRow(row) }
                }
            } else {
                if !model.live.isEmpty {
                    // iPhone (MobileAutomations): each live run is its own card.
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        SHListHeader("Running now")
                        VStack(spacing: MobileLayout.blockSpacing) {
                            ForEach(model.live) { row in
                                AutomationRunCardView(row: row) { open(row.key) }.equatable()
                            }
                        }
                    }
                }
                if !model.quiet.isEmpty {
                    section("All", count: model.rows.count, rows: model.quiet)
                }
            }
            pauseAll
            if !store.readOnlyNotes.isEmpty {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    ForEach(store.readOnlyNotes, id: \.self) { note in
                        Text(note).shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                .padding(.horizontal, SH.Space.xs)
            }
        }
    }

    /// Pause all triggers, per host that has triggered automations and takes the change.
    @ViewBuilder private var pauseAll: some View {
        let hosts = store.pauseAllHosts
        if !hosts.isEmpty {
            SHListCard {
                ForEach(hosts, id: \.id) { host in
                    HStack(spacing: SH.Space.m) {
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(hosts.count > 1 ? "Pause all triggers on \(host.name)" : "Pause all triggers")
                                .font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                            Text("Schedules and GitHub start no runs while it's on.")
                                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                        }
                        .accessibilityHidden(true)
                        Spacer(minLength: SH.Space.m)
                        SHAutomationSwitch(hosts.count > 1 ? "Pause all triggers on \(host.name)" : "Pause all triggers",
                                           isOn: store.isAllPaused(host.id),
                                           toggle: host.enabled ? { store.setAllPaused(host: host.id, $0) } : nil)
                    }
                    .padding(.horizontal, SH.Space.l)
                    .padding(.vertical, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func padRow(_ row: AutomationListRow) -> some View {
        AutomationListRowView(row: row, isOn: store.isOn(row), busy: store.busy.contains(row.key),
                              selected: row.key == chosen, chevron: false,
                              toggle: { store.setEnabled(row.key, $0) }, open: { open(row.key) })
            .equatable()
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
    }

    private func section(_ title: String, count: Int, rows: [AutomationListRow]) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            SHListHeader(title, count: count)
            SHListCard {
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
        SHAutomationRow(row.name, when: ([row.when, row.hostTag ?? row.place] + (row.unread > 0 ? ["\(row.unread) unread"] : [])).joined(separator: " · "),
                        status: row.status,
                        statusTone: row.tone == .stopped || row.tone == .off ? nil : state, clock: clock,
                        leading: row.tone == .running ? .running : .symbol("bolt", row.tone == .attention ? .attention : nil),
                        // Read-only (offline, or an older host): the "when" line says whether it is on.
                        isOn: row.abilities.toggle ? isOn : nil, switchEnabled: !busy, selected: selected,
                        dimmed: row.offline || !isOn, chevron: chevron, toggle: toggle, open: open)
    }

    private var clock: SHRowClock? {
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
        SHAutomationRunCard(row.name, host: row.hostTag ?? row.hostName, status: row.status, asking: row.tone == .attention,
                            since: since, open: open)
    }
}

/// iPad: the list beside the chosen automation's detail.
private struct AutomationsSplit: View {
    let store: AutomationsStore
    let model: AutomationsModel
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let current = model.rows.first { $0.key == store.chosen }?.key ?? model.rows[0].key
        PadListDetail(listWidth: MobileLayout.automationsListWidth) {
            ScrollView {
                AutomationsList(store: store, model: model, chosen: current) { store.chosen = $0 }
                    .padding(SH.Space.m)
            }
            .refreshable { await store.refresh() }
        } detail: {
            AutomationDetailContent(key: current, pad: true)
        } single: {
            // Too narrow for both (iPhone Duo): the list, each row pushing its detail.
            ScrollView {
                AutomationsList(store: store, model: model, chosen: nil) { key in
                    navigator.open(.automations(.detail(host: key.host, automation: key.automation)))
                }
                .padding(.horizontal, MobileLayout.gutter)
                .padding(.bottom, MobileLayout.sectionSpacing)
            }
            .refreshable { await store.refresh() }
        }
    }
}


/// The hosts that get a Pause all triggers switch: those with a triggered automation.
enum AutomationsPauseAll {
    struct Host: Equatable {
        let id: UUID
        let name: String
        /// It's connected and takes trigger changes.
        let enabled: Bool
    }

    static func hosts(_ rows: [AutomationListRow]) -> [Host] {
        var seen = Set<UUID>()
        return rows.filter(\.triggered).compactMap { row in
            guard seen.insert(row.key.host).inserted else { return nil }
            return Host(id: row.key.host, name: row.hostName, enabled: row.abilities.triggers)
        }
    }
}

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
                            .buttonStyle(.settingsPill(.dark))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(AutomationsPhoneBar(store: store))
            } else if sizeClass == .regular, let selection = store.selection {
                AutomationsSplit(store: store, model: model, current: selection)
            } else {
                AutomationsPhoneList(store: store, model: model)
            }
        }
        .background(Color.sh.bgWindow)
        .task { await store.watch() }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
    }
}

/// The phone's list (MobileAutomations): the 28pt title over Running now and All.
private struct AutomationsPhoneList: View {
    let store: AutomationsStore
    let model: AutomationsModel
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
                SettingsHeading("Automations")
                AutomationsList(store: store, model: model, chosen: nil) { key in AutomationsHooks.open(key, navigator: navigator) }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
        }
        .refreshable { await store.refresh() }
        .modifier(AutomationsPhoneBar(store: store))
    }
}

/// The phone's bar: the ··· menu (Pause all triggers, per host that has triggered automations and takes the
/// change) and New automation as the ink circle (MobileAutomations).
private struct AutomationsPhoneBar: ViewModifier {
    let store: AutomationsStore
    @Environment(MobileNavigator.self) private var navigator

    func body(content: Content) -> some View {
        content.toolbar {
            if !store.pauseAllHosts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { AutomationsMenu(store: store) }
            }
            if !store.editableHosts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New automation", systemImage: "plus") { AutomationsHooks.create(navigator: navigator) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .tint(Color.sh.primary)
                }
            }
        }
    }
}

/// ··· : Pause all triggers on each host that takes it.
struct AutomationsMenu: View {
    let store: AutomationsStore

    var body: some View {
        let paused = store.pauseAllHosts
        Menu("Pause all triggers", systemImage: "ellipsis") {
            ForEach(paused, id: \.id) { host in
                Toggle(paused.count > 1 ? "Pause all triggers on \(host.name)" : "Pause all triggers",
                       isOn: Binding(get: { store.isAllPaused(host.id) }, set: { store.setAllPaused(host: host.id, $0) }))
                    .disabled(!host.enabled)
            }
        }
        .labelStyle(.iconOnly)
        .tint(Color.sh.textPrimary)
    }
}

/// The list: a failure's banner, Running now and All (each its own list on iPad), and why a host's
/// automations are read-only.
private struct AutomationsList: View {
    let store: AutomationsStore
    let model: AutomationsModel
    /// The row the iPad shows beside the list.
    let chosen: AutomationKey?
    let open: (AutomationKey) -> Void

    var body: some View {
        let pad = chosen != nil
        LazyVStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
            if let failure = store.failure {
                SHBanner(.failed, title: failure.message) {
                    Button("OK") { store.failure = nil }.buttonStyle(.settingsPill)
                }
            }
            if !model.live.isEmpty {
                VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                    SettingsCaption("Running now", tone: pad ? .quiet : .loud, count: model.live.count)
                    if pad {
                        LazyVStack(spacing: SH.Space.xxs) {
                            ForEach(model.live) { row in
                                AutomationLiveRow(row: row, selected: row.key == chosen, chevron: false) { open(row.key) }
                                    .equatable()
                                    .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
                            }
                        }
                    } else {
                        SettingsLazyCard(model.live) { row in
                            AutomationLiveRow(row: row, selected: false, chevron: true) { open(row.key) }.equatable()
                        }
                    }
                }
            }
            if !model.quiet.isEmpty {
                VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                    SettingsCaption("All", tone: pad ? .quiet : .loud, count: model.rows.count)
                    if pad {
                        LazyVStack(spacing: SH.Space.xxs) {
                            ForEach(model.quiet) { row in allRow(row, selected: row.key == chosen)
                                .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
                            }
                        }
                    } else {
                        SettingsLazyCard(model.quiet) { row in allRow(row, selected: false) }
                    }
                }
            }
            if !store.pauseAllHosts.isEmpty {
                SettingsFootnote("Pause all triggers on a host from ···. Schedules and GitHub start no runs while it’s on.")
            }
            ForEach(store.readOnlyNotes, id: \.self) { note in
                SettingsFootnote(note)
            }
        }
    }

    private func allRow(_ row: AutomationListRow, selected: Bool) -> some View {
        AutomationAllRow(row: row, isOn: store.isOn(row), busy: store.busy.contains(row.key), selected: selected,
                         toggle: { store.setEnabled(row.key, $0) }, open: { open(row.key) })
            .equatable()
    }
}

/// iPad: the list beside the chosen automation's detail, each under its own bar (iPadAutomations).
private struct AutomationsSplit: View {
    let store: AutomationsStore
    let model: AutomationsModel
    let current: AutomationKey
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        PadListDetail(listWidth: MobileLayout.automationsListWidth) {
            VStack(spacing: 0) {
                PadColumnBar(title: "Automations", subtitle: "\(model.live.count) running · \(model.rows.count) in all") {
                    HStack(spacing: SH.Space.m) {
                        if !store.pauseAllHosts.isEmpty { AutomationsMenu(store: store).buttonStyle(.glass) }
                        if !store.editableHosts.isEmpty {
                            PadBarPrimary(title: "New automation", systemImage: "plus") { AutomationsHooks.create(navigator: navigator) }
                        }
                    }
                }
                ScrollView {
                    AutomationsList(store: store, model: model, chosen: current) { store.chosen = $0 }
                        .padding(SH.Space.m)
                }
                .refreshable { await store.refresh() }
            }
        } detail: {
            AutomationDetailContent(key: current, pad: true)
        } single: {
            // Too narrow for both (iPhone Duo): the phone's list, each row pushing its detail.
            ScrollView {
                VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
                    SettingsHeading("Automations")
                    AutomationsList(store: store, model: model, chosen: nil) { key in
                        navigator.open(.automations(.detail(host: key.host, automation: key.automation)))
                    }
                }
                .padding(.horizontal, MobileLayout.gutter)
                .padding(.bottom, MobileLayout.sectionSpacing)
            }
            .refreshable { await store.refresh() }
            .modifier(AutomationsPhoneBar(store: store))
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

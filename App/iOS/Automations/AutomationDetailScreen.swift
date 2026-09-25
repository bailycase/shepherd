import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One automation on its own (iPhone, pushed from the list).
struct AutomationDetailScreen: View {
    let key: AutomationKey
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = AutomationsStore.of(hosts)
        AutomationDetailContent(key: key, pad: false)
            .background(Color.nw.bgWindow)
            .task { await store.watch() }
            .navigationTitle(store.details[key]?.row.name ?? "Automation")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// An automation's detail (iPadAutomations' right column, MobileAutomations' pushed screen):
/// its switch and facts, the prompt, the chart of its latest runs, the last run, and every run
/// the host kept, each opening as its thread while that thread exists. Edit and Run now (or
/// Stop) sit at the bottom; Delete is in the ••• menu.
struct AutomationDetailContent: View {
    let key: AutomationKey
    let pad: Bool
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var confirmingDelete = false
    @State private var confirmingStop = false

    var body: some View {
        let store = AutomationsStore.of(hosts)
        if let detail = store.details[key] {
            content(detail, store: store)
        } else {
            NWEmptyState(Text("Automation gone"), message: "This automation is no longer on its host.") { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ detail: AutomationDetail, store: AutomationsStore) -> some View {
        let row = detail.row
        let busy = store.busy.contains(key)
        return ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if pad { header(row, on: store.isOn(row)) }
                if let failure = store.failure, !pad {
                    NWBanner(.failed, title: failure.message) {
                        Button("OK") { store.failure = nil }.buttonStyle(.nw(.secondary))
                    }
                }
                VStack(spacing: 0) {
                    NWFactRow("On") {
                        let on = store.isOn(row)
                        NWAutomationSwitch("Starts with Shepherd", isOn: on,
                                           caption: on ? "Runs when Shepherd starts on \(row.hostName)" : "Runs only when you run it",
                                           toggle: row.abilities.toggle && !busy ? { store.setEnabled(key, $0) } : nil)
                    }
                    NWFactRow("Status") {
                        NWFactText(row.status)
                            .foregroundStyle(row.tone == .stopped || row.tone == .off ? Color.nw.textPrimary : AgentState(row.tone).textColor)
                    }
                    NWFactRow("Runs on", value: "\(row.hostName) · a new thread each run", mono: true)
                    NWFactRow("Folder", value: row.cwd, mono: true)
                }
                NWAutomationPrompt(row.prompt)
                runs(detail)
                if let reason = row.abilities.readOnlyReason {
                    Text(reason).nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                }
            }
            .padding(MobileLayout.gutter)
            .frame(maxWidth: pad ? MobileLayout.automationDetailMaxWidth : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: pad ? .leading : .center)
        }
        .refreshable { await store.refreshRuns() }
        .safeAreaInset(edge: .bottom) { actions(row, busy: busy, store: store) }
        .toolbar {
            if !pad {
                ToolbarItem(placement: .primaryAction) { menu(row) }
            }
        }
        .confirmationDialog("Delete \(row.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Automation", role: .destructive) {
                store.delete(key)
                if !pad { navigator.popToRoot() }
            }
        } message: {
            Text("It stops its run and is removed from \(row.hostName). Its runs are forgotten.")
        }
        .confirmationDialog("Stop the run?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Run", role: .destructive) { store.stop(key) }
        } message: {
            Text("Its thread on \(row.hostName) is deleted. The automation stays.")
        }
    }

    /// iPad: the name, its On or Off, and the ••• menu (iPadAutomations' detail header).
    private func header(_ row: AutomationListRow, on: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Text(row.name).nwText(.title).foregroundStyle(Color.nw.textPrimary)
                .accessibilityAddTraits(.isHeader)
            NWStatusPill(on ? .done : .idle, label: on ? "On" : "Off")
            Spacer(minLength: NW.Space.s)
            menu(row)
        }
    }

    private func menu(_ row: AutomationListRow) -> some View {
        Menu {
            if let run = row.run {
                Button("Open Run", systemImage: "text.bubble") { navigator.open(.thread(AgentRef(host: run.host, agent: run.agent))) }
            }
            Button("Edit", systemImage: "pencil") { edit() }.disabled(!row.abilities.edit)
            Button("Delete Automation", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                .disabled(!row.abilities.edit)
        } label: {
            Image(systemName: "ellipsis")
                .nwTouchTarget(height: NW.Height.controlS, width: NW.Height.controlS)
        }
        .accessibilityLabel("More for \(row.name)")
    }

    @ViewBuilder
    private func runs(_ detail: AutomationDetail) -> some View {
        if !detail.runsKnown {
            if detail.row.abilities.readOnlyReason == nil {
                HStack(spacing: NW.Space.s) {
                    ProgressView().progressViewStyle(.nwSpinner)
                    Text("Reading runs…").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                }
            }
        } else if detail.runs.isEmpty {
            Text("No runs yet. Run now starts one.").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
        } else {
            NWRunBars(detail.bars.map { NWRunBars.Bar(id: $0.id.uuidString, height: $0.height, state: AgentState($0.tone), label: $0.label) },
                      first: detail.chartStart, summary: detail.chartSummary, last: detail.chartEnd)
                .padding(NW.Space.l)
                .nwCard(radius: MobileLayout.cardRadius)
            if let last = detail.lastRun {
                VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                    NWListHeader("Last run")
                    runRow(last)
                        .padding(NW.Space.xs)
                        .nwCard(radius: MobileLayout.cardRadius)
                }
            }
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                NWListHeader("Runs", count: detail.runs.count)
                NWListCard {
                    ForEach(detail.runs) { run in runRow(run).padding(.horizontal, NW.Space.xs) }
                }
            }
        }
    }

    private func runRow(_ run: AutomationRunRow) -> some View {
        NWRunRow(started: run.started, word: run.word, state: AgentState(run.tone), duration: run.duration,
                 open: run.agent.map { agent in { navigator.open(.thread(AgentRef(host: agent.host, agent: agent.agent))) } })
    }

    /// Edit and Run now, or Stop and Open run while it runs (the boards' footer).
    private func actions(_ row: AutomationListRow, busy: Bool, store: AutomationsStore) -> some View {
        HStack(spacing: NW.Space.m) {
            Button("Edit") { edit() }
                .buttonStyle(.nw(.secondary, size: .l))
                .disabled(!row.abilities.edit)
            Spacer(minLength: NW.Space.s)
            if let run = row.run {
                Button("Stop") { confirmingStop = true }
                    .buttonStyle(.nw(.secondary, size: .l))
                    .disabled(!row.abilities.stop || busy)
                Button("Open run") { navigator.open(.thread(AgentRef(host: run.host, agent: run.agent))) }
                    .buttonStyle(.nw(.primary, size: .l))
            } else {
                Button("Run now", systemImage: "play.fill") { store.run(key) }
                    .buttonStyle(.nw(.primary, size: .l))
                    .disabled(!row.abilities.run || busy)
            }
        }
        .nwTouchTarget(height: NW.Height.controlL)
        .frame(maxWidth: pad ? MobileLayout.automationDetailMaxWidth - 2 * MobileLayout.gutter : .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, NW.Space.m)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
    }

    private func edit() {
        navigator.present(.automations(.edit(host: key.host, automation: key.automation)))
    }
}

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
            .background(Color.sh.bgWindow)
            .task { await store.watch() }
            .navigationTitle(store.details[key]?.row.name ?? "Automation")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// An automation's detail (iPadAutomations' right column, MobileAutomations' pushed screen):
/// its switch and facts, the prompt, the chart of its latest runs, the last run, and every run
/// the host kept, each opening as its thread while that thread exists. Edit and Run now (or
/// Stop while a run is live) sit at the bottom; Delete is in the ••• menu.
struct AutomationDetailContent: View {
    let key: AutomationKey
    let pad: Bool
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = AutomationsStore.of(hosts)
        if let detail = store.details[key] {
            content(detail, store: store)
        } else {
            SHEmptyState(Text("Automation gone"), message: "This automation is no longer on its host.") { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ detail: AutomationDetail, store: AutomationsStore) -> some View {
        let row = detail.row
        let busy = store.busy.contains(key)
        return ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if pad { header(row, on: store.isOn(row), store: store) }
                if let failure = store.failure, !pad {
                    SHBanner(.failed, title: failure.message) {
                        Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
                    }
                }
                VStack(spacing: 0) {
                    SHFactRow("On") {
                        let on = store.isOn(row)
                        SHAutomationSwitch("Starts with Shepherd", isOn: on,
                                           caption: on ? "Runs when Shepherd starts on \(row.hostName)" : "Runs only when you run it",
                                           toggle: row.abilities.toggle && !busy ? { store.setEnabled(key, $0) } : nil)
                    }
                    SHFactRow("Status") {
                        SHFactText(row.status)
                            .foregroundStyle(row.tone == .stopped || row.tone == .off ? Color.sh.textPrimary : AgentState(row.tone).textColor)
                    }
                    SHFactRow("Runs on", value: "\(row.hostName) · a new thread each run", mono: true)
                    SHFactRow("Folder", value: row.cwd, mono: true)
                }
                SHAutomationPrompt(row.prompt)
                runs(detail)
                if let reason = row.abilities.readOnlyReason {
                    Text(reason).shText(.caption).foregroundStyle(Color.sh.textTertiary)
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
                ToolbarItem(placement: .primaryAction) { menu(row, store: store) }
            }
        }
    }

    /// Whether `kind` is being asked about here, for a confirmation dialog anchored on the
    /// control that asks (a popover's arrow points at it on iPad and wide iPhones).
    private func confirming(_ kind: AutomationsStore.Confirmation.Kind, store: AutomationsStore) -> Binding<Bool> {
        let asked = AutomationsStore.Confirmation(key: key, kind: kind)
        return Binding(get: { store.confirming == asked },
                       set: { if $0 { store.confirming = asked } else if store.confirming == asked { store.confirming = nil } })
    }

    /// iPad: the name, its On or Off, and the ••• menu (iPadAutomations' detail header).
    private func header(_ row: AutomationListRow, on: Bool, store: AutomationsStore) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(row.name).shText(.title).foregroundStyle(Color.sh.textPrimary)
                .accessibilityAddTraits(.isHeader)
            SHStatusPill(on ? .done : .idle, label: on ? "On" : "Off")
            Spacer(minLength: SH.Space.s)
            menu(row, store: store)
        }
    }

    private func menu(_ row: AutomationListRow, store: AutomationsStore) -> some View {
        Menu {
            if let run = row.run {
                Button("Open Run", systemImage: "text.bubble") { navigator.open(.thread(AgentRef(host: run.host, agent: run.agent))) }
            }
            Button("Edit", systemImage: "pencil") { edit() }.disabled(!row.abilities.edit)
            Button("Delete Automation", systemImage: "trash", role: .destructive) { store.confirming = .init(key: key, kind: .delete) }
                .disabled(!row.abilities.edit)
        } label: {
            Image(systemName: "ellipsis")
                .shTouchTarget(height: SH.Height.controlS, width: SH.Height.controlS)
        }
        .accessibilityLabel("More for \(row.name)")
        .confirmationDialog("Delete \(row.name)?", isPresented: confirming(.delete, store: store), titleVisibility: .visible) {
            Button("Delete Automation", role: .destructive) {
                // The iPhone's detail closes once the host has removed it; the list stays.
                let detail = MobileRoute.automations(.detail(host: key.host, automation: key.automation))
                store.delete(key) { navigator.close(detail) }
            }
        } message: {
            Text("It stops its run and is removed from \(row.hostName). Its runs are forgotten.")
        }
    }

    @ViewBuilder
    private func runs(_ detail: AutomationDetail) -> some View {
        if !detail.runsKnown {
            if detail.row.abilities.readOnlyReason == nil {
                HStack(spacing: SH.Space.s) {
                    ProgressView().progressViewStyle(.shSpinner)
                    Text("Reading runs…").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                }
            }
        } else if detail.runs.isEmpty {
            Text("No runs yet. Run now starts one.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
        } else {
            let bars = SHRunBars(detail.bars.map { SHRunBars.Bar(id: $0.id.uuidString, height: $0.height, state: AgentState($0.tone), label: $0.label) },
                                 first: detail.chartStart, summary: detail.chartSummary, last: detail.chartEnd)
            if pad {
                // iPadAutomations: the bars on the page, then the last run as a card.
                bars
                if let last = detail.lastRun { lastRunCard(last) }
            } else {
                bars
                    .padding(SH.Space.l)
                    .shCard(radius: MobileLayout.cardRadius)
            }
            if !pad, let last = detail.lastRun {
                VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                    SHListHeader("Last run")
                    runRow(last)
                        .padding(SH.Space.xs)
                        .shCard(radius: MobileLayout.cardRadius)
                }
            }
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                SHListHeader("Runs", count: detail.runs.count)
                SHListCard {
                    ForEach(detail.runs) { run in runRow(run).padding(.horizontal, SH.Space.xs) }
                }
            }
        }
    }

    /// iPadAutomations' last-run card: its glyph, "Today 02:00 · finished in 43s", and Open thread.
    private func lastRunCard(_ run: AutomationRunRow) -> some View {
        let sh = Color.sh
        let state = AgentState(run.tone)
        return HStack(spacing: SH.Space.m) {
            SHStateGlyph(state)
            Text([run.started, run.duration.map { "\(run.word) in \($0)" } ?? run.word].joined(separator: " · "))
                .font(.sh(.ui, weight: .semibold))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
            Spacer(minLength: SH.Space.s)
            if let agent = run.agent {
                Button("Open thread") { navigator.open(.thread(AgentRef(host: agent.host, agent: agent.agent))) }
                    .buttonStyle(.shLink(color: sh.running, font: .sh(.ui)))
                    .shTouchTarget(height: SH.Height.controlL)
            }
        }
        .padding(.horizontal, SH.Space.l + SH.Space.xxs)
        .padding(.vertical, SH.Space.l)
        .shCard(radius: MobileLayout.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last run, \(run.started), \(run.word)\(run.duration.map { " in \($0)" } ?? "")")
    }

    private func runRow(_ run: AutomationRunRow) -> some View {
        SHRunRow(started: run.started, word: run.word, state: AgentState(run.tone), duration: run.duration,
                 open: run.agent.map { agent in { navigator.open(.thread(AgentRef(host: agent.host, agent: agent.agent))) } })
    }

    /// Edit and Run now (with Open run while the last run's thread is there; running again
    /// replaces it), or Stop and Open run while a run is live (the boards' footer).
    private func actions(_ row: AutomationListRow, busy: Bool, store: AutomationsStore) -> some View {
        HStack(spacing: SH.Space.m) {
            Button("Edit") { edit() }
                .buttonStyle(.sh(.secondary, size: .l))
                .disabled(!row.abilities.edit)
            Spacer(minLength: SH.Space.s)
            if row.live, let run = row.run {
                Button("Stop") { store.confirming = .init(key: key, kind: .stop) }
                    .buttonStyle(.sh(.secondary, size: .l))
                    .disabled(!row.abilities.stop || busy)
                    .confirmationDialog("Stop the run?", isPresented: confirming(.stop, store: store), titleVisibility: .visible) {
                        Button("Stop Run", role: .destructive) { store.stop(key) }
                    } message: {
                        Text("Its thread on \(row.hostName) is deleted. The automation stays.")
                    }
                Button("Open run") { navigator.open(.thread(AgentRef(host: run.host, agent: run.agent))) }
                    .buttonStyle(.sh(.primary, size: .l))
            } else {
                if let run = row.run {
                    Button("Open run") { navigator.open(.thread(AgentRef(host: run.host, agent: run.agent))) }
                        .buttonStyle(.sh(.secondary, size: .l))
                }
                Button("Run now", systemImage: "play.fill") { store.run(key) }
                    .buttonStyle(.sh(.primary, size: .l))
                    .disabled(!row.abilities.run || busy)
            }
        }
        .shTouchTarget(height: SH.Height.controlL)
        .frame(maxWidth: pad ? MobileLayout.automationDetailMaxWidth - 2 * MobileLayout.gutter : .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.m)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .top) { SHHairline() }
    }

    private func edit() {
        navigator.present(.automations(.edit(host: key.host, automation: key.automation)))
    }
}

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
                if let trigger = detail.trigger {
                    // The inbox first: how the trigger stands, what waits, what ran; then its settings.
                    triggerBanner(trigger, row: row)
                    triggerHead(trigger, row: row, busy: busy, store: store)
                    if let note = store.zoneNotes[key.host], trigger.next != nil || trigger.checked != nil {
                        Text(note).shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    }
                    if !trigger.pending.isEmpty { pending(trigger, row: row, busy: busy, store: store) }
                    runs(detail)
                    triggerSettings(trigger, row: row)
                } else {
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
                }
                SHAutomationPrompt(row.prompt)
                if detail.trigger == nil { runs(detail) }
                if let reason = row.abilities.readOnlyReason {
                    Text(reason).shText(.caption).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .padding(MobileLayout.gutter)
            .frame(maxWidth: pad ? MobileLayout.automationDetailMaxWidth : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: pad ? .leading : .center)
        }
        .refreshable { await store.refresh() }
        .safeAreaInset(edge: .bottom) { actions(row, trigger: detail.trigger, busy: busy, store: store) }
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
            if let state = store.details[key]?.trigger?.state, on {
                SHStatusPill(AgentState(state.tone), label: state.word)
            } else {
                SHStatusPill(on ? .done : .idle, label: on ? "On" : "Off")
            }
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
                    if detail.trigger != nil {
                        ForEach(detail.runs) { run in
                            AutomationInboxRunRow(run: run, open: run.agent.map { agent in { open(run: run, agent: agent) } })
                                .equatable()
                                .padding(.horizontal, SH.Space.xs)
                        }
                    } else {
                        ForEach(detail.runs) { run in runRow(run).padding(.horizontal, SH.Space.xs) }
                    }
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

    /// Opens a run's thread and clears its unread dot.
    private func open(run: AutomationRunRow, agent: FleetRef) {
        if run.unread { AutomationsStore.of(hosts).markRead(key, runID: run.id) }
        navigator.open(.thread(AgentRef(host: agent.host, agent: agent.agent)))
    }

    // MARK: Triggered

    /// Why the trigger is paused or retrying (Resume is in the footer).
    @ViewBuilder
    private func triggerBanner(_ trigger: AutomationTriggerDetail, row: AutomationListRow) -> some View {
        if let state = trigger.state, row.enabled, let reason = state.reason {
            SHBanner(state.tone == .failed ? .failed : .attention, title: "\(state.word): \(reason)",
                     message: trigger.retry.map { "Checks again \($0)." } ?? (state.paused ? "Resume checks again now." : nil)) { EmptyView() }
        }
    }

    /// The switch, what fires it and how it stands.
    private func triggerHead(_ trigger: AutomationTriggerDetail, row: AutomationListRow, busy: Bool, store: AutomationsStore) -> some View {
        VStack(spacing: 0) {
            SHFactRow("On") {
                let on = store.isOn(row)
                SHAutomationSwitch("On", isOn: on, caption: on ? "Its trigger starts runs" : "Nothing fires until it's on",
                                   toggle: row.abilities.toggle && !busy ? { store.setEnabled(key, $0) } : nil)
            }
            SHFactRow("Trigger", value: trigger.summary)
            SHFactRow("Status") {
                if let state = trigger.state {
                    SHFactText(state.word)
                        .foregroundStyle(state.tone == .stopped || state.tone == .off ? Color.sh.textPrimary : AgentState(state.tone).textColor)
                } else if row.abilities.triggers {
                    SHFactText("Reading…").foregroundStyle(Color.sh.textTertiary)
                } else {
                    SHFactText(row.status)
                }
            }
            if let next = trigger.next { SHFactRow("Next run", value: next, mono: true) }
            if let checked = trigger.checked { SHFactRow("Checked", value: checked, mono: true) }
            if let today = trigger.today { SHFactRow("Today", value: today) }
        }
    }

    /// Where and how its runs go.
    private func triggerSettings(_ trigger: AutomationTriggerDetail, row: AutomationListRow) -> some View {
        VStack(spacing: 0) {
            SHFactRow("Runs on", value: trigger.runsOn, mono: true)
            SHFactRow("Folder", value: row.cwd, mono: true)
            if let workspace = trigger.workspace { SHFactRow("Works in", value: workspace) }
            if let gate = trigger.gate {
                SHFactRow("Who can trigger") {
                    SHFactText(gate)
                        .foregroundStyle(trigger.gateWarning == nil ? Color.sh.textPrimary : Color.sh.lanternText)
                }
            }
            SHFactRow("Limits", value: trigger.limits)
            SHFactRow("Model", value: trigger.model, mono: trigger.model != "Default")
        }
    }

    /// Events waiting for a free slot: Run now (past the limits) or Dismiss each.
    private func pending(_ trigger: AutomationTriggerDetail, row: AutomationListRow, busy: Bool, store: AutomationsStore) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            SHListHeader("Waiting", count: trigger.pending.count)
            SHListCard {
                ForEach(trigger.pending) { event in
                    AutomationPendingRowView(event: event, enabled: row.abilities.triggers && !busy,
                                             run: { store.runEvent(key, eventID: event.id) },
                                             dismiss: { store.dismissEvent(key, eventID: event.id) })
                        .equatable()
                        .padding(.horizontal, SH.Space.xs)
                }
            }
            Text("Run now starts one past today's limit.").shText(.caption).foregroundStyle(Color.sh.textTertiary)
                .padding(.horizontal, SH.Space.xs)
        }
    }

    /// Edit and Run now (with Open run while the last run's thread is there; running again
    /// replaces it), or Stop and Open run while a run is live (the boards' footer). A triggered
    /// automation's runs are each their own thread: Edit, Pause or Resume, and Run now.
    private func actions(_ row: AutomationListRow, trigger: AutomationTriggerDetail?, busy: Bool, store: AutomationsStore) -> some View {
        HStack(spacing: SH.Space.m) {
            Button("Edit") { edit() }
                .buttonStyle(.sh(.secondary, size: .l))
                .disabled(!row.abilities.edit)
            Spacer(minLength: SH.Space.s)
            if let trigger {
                if row.enabled, let state = trigger.state, state.tone != .off {
                    Button(state.paused ? "Resume" : "Pause") { state.paused ? store.resume(key) : store.pause(key) }
                        .buttonStyle(.sh(.secondary, size: .l))
                        .disabled(!row.abilities.triggers || busy)
                }
                Button("Run now", systemImage: "play.fill") { store.run(key) }
                    .buttonStyle(.sh(.primary, size: .l))
                    .disabled(!row.abilities.run || busy)
            } else if row.live, let run = row.run {
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

/// One run of a triggered automation: an unread dot until its thread is opened, what fired it,
/// how it went, why it didn't start, and its pull request.
struct AutomationInboxRunRow: View, Equatable {
    let run: AutomationRunRow
    let open: (() -> Void)?

    static func == (a: Self, b: Self) -> Bool { a.run == b.run && (a.open == nil) == (b.open == nil) }

    var body: some View {
        HStack(spacing: SH.Space.s) {
            if let open {
                Button(action: open) { content }
                    .buttonStyle(.shRow(radius: SH.Radius.s))
                    .accessibilityHint("Opens its thread")
            } else {
                content
            }
            if let pr = run.pullRequestURL {
                Link("PR", destination: pr)
                    .buttonStyle(.shLink(color: Color.sh.running, font: .sh(.ui, weight: .semibold)))
                    .shTouchTarget(height: SH.Height.touch)
                    .accessibilityLabel("Open pull request")
            }
        }
        .contextMenu {
            if let url = run.triggerURL { Link("Open on GitHub", destination: url) }
            if let pr = run.pullRequestURL { Link("Open Pull Request", destination: pr) }
        }
    }

    private var content: some View {
        let sh = Color.sh
        let state = AgentState(run.tone)
        return HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            SHStatusDot(.running)
                .opacity(run.unread ? 1 : 0)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(run.trigger ?? "Run now")
                    .font(.sh(.ui, weight: run.unread ? .semibold : .regular))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(2)
                HStack(spacing: SH.Space.s) {
                    Text(run.word).foregroundStyle(state.textColor)
                    Text([run.started, run.duration].compactMap { $0 }.joined(separator: " · "))
                        .font(.sh(.mono)).foregroundStyle(sh.textTertiary)
                }
                .font(.sh(.caption))
                .lineLimit(1)
                if let failure = run.failure {
                    Text(failure).font(.sh(.caption)).foregroundStyle(sh.failed).lineLimit(3)
                }
            }
            Spacer(minLength: SH.Space.s)
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SH.Space.s)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([run.unread ? "Unread" : nil, run.trigger ?? "Run now", run.word, run.started, run.duration, run.failure]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// An event waiting in a triggered automation's inbox.
struct AutomationPendingRowView: View, Equatable {
    let event: AutomationPendingRow
    let enabled: Bool
    let run: () -> Void
    let dismiss: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.event == b.event && a.enabled == b.enabled }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                if let url = event.url {
                    Link(destination: url) {
                        Text(event.summary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(2)
                        .accessibilityHint("Opens it on GitHub")
                } else {
                    Text(event.summary).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(2)
                }
                Text(event.when).font(.sh(.mono)).foregroundStyle(sh.textTertiary)
            }
            HStack(spacing: SH.Space.m) {
                // Secondary: the footer's Run now stays the screen's one primary action.
                Button("Run now", systemImage: "play.fill", action: run)
                    .buttonStyle(.sh(.secondary, size: .s))
                    .accessibilityLabel("Run now: \(event.summary)")
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.sh(.secondary, size: .s))
                    .accessibilityLabel("Dismiss: \(event.summary)")
            }
            .disabled(!enabled)
            .shTouchTarget(height: SH.Height.touch)
        }
        .padding(.horizontal, SH.Space.s)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

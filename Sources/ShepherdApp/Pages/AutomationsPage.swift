import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// Where a page's header starts: clear of the window controls, with the sidebar button while the
/// sidebar is not docked (as the thread toolbar).
struct PageHeaderChrome {
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?
}

/// What the Automations page's controls do. The page holds no state of its own: the filter and
/// the selection come back in its model.
struct AutomationsPageActions {
    var setFilter: (String) -> Void
    var select: (AutomationKey) -> Void
    var setEnabled: (AutomationKey, Bool) -> Void
    var run: (AutomationKey) -> Void
    var stop: (AutomationKey) -> Void
    var openThread: (FleetRef) -> Void
    var delete: (AutomationKey) -> Void
    var edit: (AutomationKey) -> Void
    var create: () -> Void
    var pause: (AutomationKey) -> Void = { _ in }
    var resume: (AutomationKey) -> Void = { _ in }
    var runEvent: (AutomationKey, String) -> Void = { _, _ in }
    var dismissEvent: (AutomationKey, String) -> Void = { _, _ in }
    /// Pause all triggers on a host (This Mac's `PageHost.localID`), or resume them.
    var setAllPaused: (UUID, Bool) -> Void = { _, _ in }
    var openURL: (URL) -> Void = { _ in }
}

/// The Automations page (NavAutomations): the header with Pause all triggers, the filter and New
/// automation, the table of every host's automations (Automation · Trigger · Host · Last run),
/// and the selected one's detail beside it: its trigger's state, what waits, its prompt, facts,
/// runs (each opening its thread), and Run now, Pause or Resume (Stop for a manual one's live
/// run) with Edit.
struct AutomationsPage: View {
    let model: AutomationsPageModel
    let actions: AutomationsPageActions
    var chrome = PageHeaderChrome()

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: "Automations", chrome: chrome) {
                if !model.hostPauses.isEmpty {
                    // Hosts have their own Pause all: one menu, a checked host is paused.
                    SHPopupMenu(model.pauseMenuTitle, minWidth: 0) {
                        Section("Pause all triggers on") {
                            if model.hasTriggers || model.allPaused {
                                Toggle(PageHost.localName, isOn: Binding(get: { model.allPaused },
                                                                         set: { actions.setAllPaused(PageHost.localID, $0) }))
                            }
                            ForEach(model.hostPauses) { host in
                                Toggle(host.name, isOn: Binding(get: { host.paused }, set: { actions.setAllPaused(host.id, $0) }))
                            }
                        }
                    }
                    .accessibilityLabel("Pause all triggers")
                    .help("Stops every schedule and GitHub trigger on a host from starting runs. Run now still works.")
                } else if model.hasTriggers || model.allPaused {
                    Toggle(isOn: Binding(get: { model.allPaused }, set: { actions.setAllPaused(PageHost.localID, $0) })) {
                        Text("Pause all triggers").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                    }
                    .toggleStyle(.shSwitch)
                    .help("Stops every schedule and GitHub trigger on this Mac from starting runs. Run now still works.")
                }
                SHPageFilterField("Filter automations", text: Binding(get: { model.filter }, set: actions.setFilter))
                Button("New automation", systemImage: "plus", action: actions.create)
                    .buttonStyle(.sh(.primary))
            }
            HStack(spacing: 0) {
                table
                if let detail = model.detail {
                    AutomationDetailPane(detail: detail, actions: actions)
                        .equatable()
                        .frame(width: AppLayout.automationDetailWidth)
                        .overlay(alignment: .leading) { SHHairline(.vertical) }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color.sh.bgWindow)
    }

    @ViewBuilder private var table: some View {
        VStack(spacing: 0) {
            SHTableHead(["Automation", "Trigger", "Host", "Last run"], columns: AppLayout.automationColumns)
                .padding(.top, AppLayout.automationTableTop)
            if let empty = model.emptyText {
                Text(empty)
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: AppLayout.automationEmptyMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            AutomationTableRowView(row: row, actions: actions)
                                .equatable()
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One table row with its context menu: the automation's actions, as the sidebar offered them.
struct AutomationTableRowView: View, Equatable {
    let row: AutomationsPageRow
    let actions: AutomationsPageActions

    nonisolated static func == (a: AutomationTableRowView, b: AutomationTableRowView) -> Bool { a.row == b.row }

    var body: some View {
        let _ = SHRenderProbe.tick("automations.row")
        let key = row.key
        SHAutomationTableRow(row.name, isOn: row.enabled, switchEnabled: row.canToggle, starts: row.trigger,
                             startsGlyph: row.triggerGlyph, note: row.note, noteState: row.noteState, unread: row.unread,
                             host: row.host, outcome: row.lastRun,
                             selected: row.selected, columns: AppLayout.automationColumns,
                             toggle: { actions.setEnabled(key, $0) }, select: { actions.select(key) })
            .contextMenu {
                if let run = row.run {
                    Button("Open Run") { actions.openThread(run) }
                    Divider()
                }
                // A settled run reads done and runs again, replacing it; only a live one stops.
                if row.live {
                    Button("Stop") { actions.stop(key) }.disabled(!row.canStop)
                } else {
                    Button("Run Now") { actions.run(key) }.disabled(!row.canRun)
                }
                Button("Edit…") { actions.edit(key) }.disabled(!row.canEdit)
                Divider()
                Button("Delete Automation", role: .destructive) { actions.delete(key) }.disabled(!row.canEdit)
                // Greyed-out items say why, as the design menus do.
                if !row.canEdit, let reason = row.disabledReason { Text(reason) }
            }
    }
}

/// The selected automation beside the table: its name and what it starts, its prompt, its facts,
/// its recent runs, and a footer with Run now (Stop while a run is live) and Edit.
struct AutomationDetailPane: View, Equatable {
    let detail: AutomationsPageDetail
    let actions: AutomationsPageActions

    nonisolated static func == (a: AutomationDetailPane, b: AutomationDetailPane) -> Bool { a.detail == b.detail }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let banner = detail.banner {
                        let key = detail.key
                        SHBanner(banner.state, title: banner.title, message: banner.message) {
                            if banner.canResume {
                                Button("Resume") { actions.resume(key) }
                                    .buttonStyle(.sh(.secondary, size: .s))
                                    .disabled(!detail.canEdit)
                            } else if banner.resumesAll {
                                Button("Resume all") { actions.setAllPaused(key.host, false) }
                                    .buttonStyle(.sh(.secondary, size: .s))
                                    .disabled(!detail.canEdit)
                            }
                        }
                        .padding(.horizontal, AppLayout.automationDetailSide)
                        .padding(.top, AppLayout.automationDetailSectionVertical)
                    }
                    if !detail.pending.isEmpty {
                        section {
                            SHPageSectionLabel("Waiting · \(detail.pending.count)")
                            Text("Each waits for a free run. Run now starts it past the limits.")
                                .font(.sh(.caption))
                                .foregroundStyle(Color.sh.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(detail.pending) { event in
                                let key = detail.key
                                SHAutomationPendingEvent(event.title, waited: event.waited, enabled: detail.canRun,
                                                         run: { actions.runEvent(key, event.id) },
                                                         dismiss: { actions.dismissEvent(key, event.id) })
                            }
                        }
                    }
                    // A triggered automation is an inbox: its runs lead, its definition follows.
                    if detail.triggered { runs.overlay(alignment: .bottom) { SHHairline() } }
                    section {
                        SHPageSectionLabel("Prompt")
                        SHPageQuote(detail.prompt)
                    }
                    section {
                        VStack(alignment: .leading, spacing: AppLayout.automationFactSpacing) {
                            ForEach(detail.facts) { fact in
                                SHPageFact(fact.label, value: fact.value, mono: fact.mono,
                                           labelWidth: AppLayout.automationFactLabelWidth, style: .detail)
                            }
                        }
                    }
                    if !detail.triggered { runs }
                }
            }
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(detail.name)
                .font(.sh(.title))
                .foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail.summary)
                .font(.shSans(12))
                .foregroundStyle(Color.sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AppLayout.automationDetailHeaderVertical)
        .padding(.horizontal, AppLayout.automationDetailSide)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) { content() }
            .padding(.vertical, AppLayout.automationDetailSectionVertical)
            .padding(.horizontal, AppLayout.automationDetailSide)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { SHHairline() }
    }

    private var runs: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            SHPageSectionLabel(detail.triggered ? "Runs" : "Recent runs")
            if let note = detail.runsNote {
                Text(note).shText(.caption).foregroundStyle(Color.sh.textTertiary)
            } else if detail.triggered {
                VStack(spacing: 0) {
                    ForEach(detail.runs) { run in
                        SHAutomationInboxRun(run.trigger ?? "Run now", started: run.started, word: run.word, state: run.state,
                                             duration: run.duration, unread: run.unread, failure: run.failure,
                                             open: run.thread.map { thread in { actions.openThread(thread) } },
                                             openPullRequest: run.pullRequest.map { url in { actions.openURL(url) } })
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(detail.runs) { run in
                        SHAutomationRunLine(started: run.started, word: run.word, state: run.state, duration: run.duration,
                                            open: run.thread.map { thread in { actions.openThread(thread) } })
                    }
                }
            }
        }
        .padding(.vertical, AppLayout.automationDetailSectionVertical)
        .padding(.horizontal, AppLayout.automationDetailSide)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        let key = detail.key
        return HStack(spacing: SH.Space.m) {
            if detail.triggered {
                Button("Run now", systemImage: "play.fill") { actions.run(key) }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .disabled(!detail.canRun)
                    .help("Starts one run now, outside the trigger and its limits")
                // A paused trigger's banner holds Resume.
                if let paused = detail.paused, !(paused && detail.banner?.canResume == true) {
                    Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.circle" : "pause") {
                        paused ? actions.resume(key) : actions.pause(key)
                    }
                    .buttonStyle(.sh(.ghost, size: .s))
                    .disabled(!detail.canEdit)
                }
            } else if detail.live {
                Button("Stop", systemImage: "stop.fill") { actions.stop(key) }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .disabled(!detail.canStop)
            } else {
                Button("Run now", systemImage: "play.fill") { actions.run(key) }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .disabled(!detail.canRun)
            }
            if let reason = detail.readOnlyReason {
                Text(reason)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: SH.Space.s)
            Button("Edit") { actions.edit(key) }
                .buttonStyle(.sh(.ghost, size: .s))
                .disabled(!detail.canEdit)
        }
        .padding(.vertical, AppLayout.automationFooterVertical)
        .padding(.horizontal, AppLayout.automationFooterSide)
        .overlay(alignment: .top) { SHHairline() }
    }
}

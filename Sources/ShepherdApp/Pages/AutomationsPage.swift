import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote
import ShepherdSidebar

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
            SHDesignsBar("Automations", leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar,
                         sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar)) {
                SHDesignsFilterField("Filter automations", text: Binding(get: { model.filter }, set: actions.setFilter))
                SHToolbarCapsule {
                    pause
                    Button("New automation", systemImage: "plus", action: actions.create)
                        .buttonStyle(.shBar)
                }
            }
            HStack(alignment: .top, spacing: AppLayout.automationPageGap) {
                table
                if let detail = model.detail {
                    AutomationDetailPane(detail: detail, actions: actions)
                        .equatable()
                        .frame(width: SHAutomationDetailMetrics.width)
                }
            }
            .padding(.leading, SHDesignsHomeMetrics.inset)
            .padding(.trailing, SH.Space.xl)
            .padding(.top, SH.Space.l)
            .padding(.bottom, SH.Space.xl)
            .frame(maxHeight: .infinity)
        }
        // The boards' window padding: the page sits inside the 8pt the sidebar's card leaves.
        .padding([.top, .trailing, .bottom], AppLayout.toolbarTop)
        .background(Color.sh.bgWindow)
    }

    /// Pause all triggers: one menu with a toggle per host, a checked host is paused. Nothing while
    /// no host has a trigger to pause.
    @ViewBuilder private var pause: some View {
        if !model.hostPauses.isEmpty || model.hasTriggers || model.allPaused {
            Menu {
                Section("Pause all triggers on") {
                    if model.hasTriggers || model.allPaused {
                        Toggle(PageHost.localName, isOn: Binding(get: { model.allPaused },
                                                                 set: { actions.setAllPaused(PageHost.localID, $0) }))
                    }
                    ForEach(model.hostPauses) { host in
                        Toggle(host.name, isOn: Binding(get: { host.paused }, set: { actions.setAllPaused(host.id, $0) }))
                    }
                }
            } label: {
                HStack(spacing: SH.Space.s) {
                    Text(model.pauseMenuTitle)
                    Image(systemName: "chevron.down").font(.shSans(SHAutomationDetailMetrics.chevron, .semibold)).foregroundStyle(Color.sh.textTertiary)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.shBar)
            .fixedSize()
            .accessibilityLabel("Pause all triggers")
            .accessibilityValue(model.pauseMenuTitle)
            .help("Stops every schedule and GitHub trigger on a host from starting runs. Run now still works.")
            SHBarDivider()
        }
    }

    @ViewBuilder private var table: some View {
        VStack(spacing: 0) {
            SHAutomationHead(["", "Automation", "Trigger", "Host", "Last run"], columns: SHAutomationTableMetrics.columns)
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
                             selected: row.selected,
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

/// The selected automation beside the table, as a card (NavAutomations' `.dcard`): its name and
/// what it starts, its prompt, its facts, its recent runs, and Run now (Stop while a run is
/// live) with Pause or Resume and Edit. The card hugs its content and scrolls past the page's height.
struct AutomationDetailPane: View, Equatable {
    let detail: AutomationsPageDetail
    let actions: AutomationsPageActions

    nonisolated static func == (a: AutomationDetailPane, b: AutomationDetailPane) -> Bool { a.detail == b.detail }

    var body: some View {
        let M = SHAutomationDetailMetrics.self
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                content
                footer
            }
            VStack(alignment: .leading, spacing: 0) {
                ScrollView { content }
                footer
            }
        }
        .padding(.bottom, M.cardBottom)
        .frame(maxWidth: .infinity, alignment: .top)
        .shCard(radius: M.radius, lift: true)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        let M = SHAutomationDetailMetrics.self
        return VStack(alignment: .leading, spacing: 0) {
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
                .padding(.horizontal, M.side)
                .padding(.top, M.labelTop)
            }
            if !detail.pending.isEmpty {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    label("Waiting · \(detail.pending.count)")
                    Text("Each waits for a free run. Run now starts it past the limits.")
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, M.side)
                    ForEach(detail.pending) { event in
                        let key = detail.key
                        SHAutomationPendingEvent(event.title, waited: event.waited, enabled: detail.canRun,
                                                 run: { actions.runEvent(key, event.id) },
                                                 dismiss: { actions.dismissEvent(key, event.id) })
                            .padding(.horizontal, M.side)
                    }
                }
            }
            // A triggered automation is an inbox: its runs lead, its definition follows.
            if detail.triggered { runs }
            label("Prompt")
            Text(detail.prompt)
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(M.promptLineSpacing)
                .foregroundStyle(Color.sh.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, M.promptVertical)
                .padding(.horizontal, M.promptHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: M.promptRadius))
                .padding(.horizontal, M.side)
            VStack(alignment: .leading, spacing: M.factGap) {
                ForEach(detail.facts) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(fact.label)
                            .font(.sh(.ui, weight: .regular))
                            .foregroundStyle(Color.sh.textSecondary)
                            .frame(width: M.factLabel, alignment: .leading)
                        Text(fact.value)
                            .font(fact.mono ? .shMono(SHTextStyle.ui.size) : .sh(.ui, weight: .regular))
                            .foregroundStyle(Color.sh.textPrimary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, M.labelTop)
            .padding(.horizontal, M.side)
            if !detail.triggered { runs }
        }
    }

    private func label(_ title: String) -> some View {
        let M = SHAutomationDetailMetrics.self
        return Text(title)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.top, M.labelTop)
            .padding(.bottom, M.labelBottom)
            .padding(.horizontal, M.side)
            .accessibilityAddTraits(.isHeader)
    }

    private var header: some View {
        let M = SHAutomationDetailMetrics.self
        return VStack(alignment: .leading, spacing: SH.Space.xxs) {
            Text(detail.name)
                .font(.shSans(M.titleSize, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail.summary)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, M.headerTop)
        .padding(.bottom, M.headerBottom)
        .padding(.horizontal, M.side)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runs: some View {
        VStack(alignment: .leading, spacing: 0) {
            label(detail.triggered ? "Runs" : "Recent runs")
            if let note = detail.runsNote {
                Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SHAutomationDetailMetrics.side)
            } else if detail.triggered {
                VStack(spacing: 0) {
                    ForEach(detail.runs) { run in
                        SHAutomationInboxRun(run.trigger ?? "Run now", started: run.started, word: run.word, state: run.state,
                                             duration: run.duration, unread: run.unread, failure: run.failure,
                                             open: run.thread.map { thread in { actions.openThread(thread) } },
                                             openPullRequest: run.pullRequest.map { url in { actions.openURL(url) } })
                    }
                }
                .padding(.horizontal, SH.Space.m)
            } else {
                VStack(spacing: 0) {
                    ForEach(detail.runs) { run in
                        SHAutomationRunLine(started: run.started, word: run.word, state: run.state, duration: run.duration,
                                            open: run.thread.map { thread in { actions.openThread(thread) } })
                    }
                }
            }
        }
    }

    /// Run now, Pause and Edit as the board's plain words: the main one in `textPrimary`, the rest quiet.
    private var footer: some View {
        let M = SHAutomationDetailMetrics.self
        let key = detail.key
        return HStack(spacing: M.actionGap) {
            if detail.triggered {
                action("Run now", "play.fill", main: true) { actions.run(key) }
                    .disabled(!detail.canRun)
                    .help("Starts one run now, outside the trigger and its limits")
                // A paused trigger's banner holds Resume.
                if let paused = detail.paused, !(paused && detail.banner?.canResume == true) {
                    action(paused ? "Resume" : "Pause", nil, main: false) { paused ? actions.resume(key) : actions.pause(key) }
                        .disabled(!detail.canEdit)
                }
            } else if detail.live {
                action("Stop", "stop.fill", main: true) { actions.stop(key) }
                    .disabled(!detail.canStop)
            } else {
                action("Run now", "play.fill", main: true) { actions.run(key) }
                    .disabled(!detail.canRun)
            }
            action("Edit", nil, main: false) { actions.edit(key) }
                .disabled(!detail.canEdit)
            if let reason = detail.readOnlyReason {
                Text(reason)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.top, M.actionTop)
        .padding(.bottom, M.actionBottom)
        .padding(.horizontal, M.side)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ title: String, _ symbol: String?, main: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: SH.Space.s) {
                if let symbol { Image(systemName: symbol).font(.shSans(SHAutomationDetailMetrics.actionGlyph - SH.Space.xxs)).accessibilityHidden(true) }
                Text(title)
            }
        }
        .buttonStyle(.shLink(color: main ? Color.sh.textPrimary : Color.sh.textSecondary,
                             font: .sh(.ui, weight: main ? .medium : .regular)))
    }
}

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
}

/// The Automations page (NavAutomations): the header with the filter and New automation, the
/// table of every host's automations (Automation · Starts · Host · Last run), and the selected
/// one's detail beside it: its prompt, facts, recent runs (each opening its thread), and Run now
/// or Stop with Edit. Automations have no schedule or trigger, so the board's When and Next
/// columns and its Scheduled and On an event tabs are left out.
struct AutomationsPage: View {
    let model: AutomationsPageModel
    let actions: AutomationsPageActions
    var chrome = PageHeaderChrome()

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: "Automations", chrome: chrome) {
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
            SHTableHead(["Automation", "Starts", "Host", "Last run"], columns: AppLayout.automationColumns)
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
        SHAutomationTableRow(row.name, isOn: row.enabled, switchEnabled: row.canToggle, host: row.host, outcome: row.lastRun,
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
                    runs
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
            SHPageSectionLabel("Recent runs")
            if let note = detail.runsNote {
                Text(note).shText(.caption).foregroundStyle(Color.sh.textTertiary)
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
            if detail.live {
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

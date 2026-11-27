import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// The iPad detail with no thread selected (iPadOverview board; home track): Needs you with the
/// answers that fit in place, what runs now, and what finished, side by side when there is room.
/// With nothing in any column it is an empty state with New thread.
struct PadOverview: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Three columns at their narrowest, and the gaps between them.
    private static let sideBySideWidth = MobileLayout.overviewColumnMinWidth * 3 + MobileLayout.blockSpacing * 2

    var body: some View {
        VerticalBars { inline in content(inline: inline) }
    }

    @ViewBuilder private func content(inline: Bool) -> some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        let sidebarHidden = navigator.padColumns == .detailOnly && navigator.padPath.isEmpty
        Group {
            if hosts.hosts.isEmpty {
                NoHostsState().frame(maxHeight: .infinity)
            } else if model.overviewIsEmpty {
                // Fills the screen with the empty state centred under the notices; with many Macs or large text it
                // scrolls instead, so New thread is never out of reach.
                let empty = VStack(spacing: 0) {
                    if !model.offlineHosts.isEmpty { HostNotices(cards: model.offlineHosts).padding(MobileLayout.gutter) }
                    SHEmptyState(Text("No thread selected"), message: "Pick a thread in the sidebar, or start a new one.") {
                        Button("New thread") { NewThreadHooks.open(navigator: navigator) }
                            .buttonStyle(.sh(.primary))
                            .accessibilityIdentifier("overview-content-new-thread")
                    }
                    .frame(maxHeight: .infinity)
                }
                ViewThatFits(in: .vertical) {
                    empty
                    ScrollView { empty }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                        HostNotices(cards: model.offlineHosts)
                        HomeReviewQueueRow()
                        // Side by side when three columns fit; stacked in a narrow window or at large text. The fit is the
                        // layout's own, not a width read back from the scroll view: that grows to its content's minimum
                        // width, so a measured width never let the columns go back to stacked once a sidebar docked.
                        ViewThatFits(in: .horizontal) {
                            if !typeSize.isAccessibilitySize {
                                HStack(alignment: .top, spacing: MobileLayout.blockSpacing) {
                                    OverviewColumns(model: model, answering: feed.answering, failures: feed.failures)
                                }
                                .frame(minWidth: Self.sideBySideWidth, idealWidth: Self.sideBySideWidth, maxWidth: .infinity)
                            }
                            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                                OverviewColumns(model: model, answering: feed.answering, failures: feed.failures)
                            }
                        }
                    }
                    .padding(MobileLayout.gutter)
                }
                .refreshable {
                    hosts.retryAll()
                    await feed.refresh()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.sh.bgWindow)
        .task { await feed.watch() }
        // Where the bar runs down the side (iPhone Duo's inner display) the head sits at the top edge, "Overview" with its summary
        // beside it (DuoOpenOverview); else the bar's leading is the title over its summary (iPadOverview).
        .safeAreaInset(edge: .top, spacing: 0) {
            if inline {
                HStack(spacing: SH.Space.m) {
                    if sidebarHidden { PadSidebarButton() }
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        Text("Overview").font(.shSans(MobileLayout.barTitleSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                        if !model.hosts.isEmpty {
                            Text(model.summary).font(.shSans(MobileLayout.barSubtitleSize)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, MobileLayout.padThreadGutter)
                .frame(maxWidth: .infinity, minHeight: SHPadPaneMetrics.duoHeadHeight, alignment: .leading)
                .background(Color.sh.bgWindow)
            }
        }
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            if sidebarHidden, !inline {
                ToolbarItem(placement: .topBarLeading) { PadSidebarButton(inBar: true) }
            }
            if !inline {
                ToolbarItem(placement: .topBarLeading) {
                    // The board's head: "Overview" over its summary.
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Overview").font(.shSans(MobileLayout.barTitleSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                        if !model.hosts.isEmpty {
                            Text(model.summary).font(.shSans(MobileLayout.barSubtitleSize)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                        }
                    }
                    .fixedSize()
                    .shBarTitleType()
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // Search and More in one capsule, New thread beside it (DuoOpenOverview, iPadOverview).
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
                    .duoStripIcon()
                StopAllWorkingMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New thread", systemImage: "plus") { NewThreadHooks.open(navigator: navigator) }
                    .duoStripIcon()
                    .buttonStyle(.glassProminent)
                    .tint(Color.sh.primary)
                    .accessibilityIdentifier("overview-toolbar-new-thread")
                    .disabled(model.hosts.isEmpty)
            }
        }
    }
}

/// Needs you, Running now and Finished, as columns or stacked.
private struct OverviewColumns: View {
    let model: FleetModel
    let answering: Set<String>
    let failures: [String: String]
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileProjects.self) private var projects

    var body: some View {
        column("Needs you", count: model.needsYou.count) {
            if model.needsYou.isEmpty {
                quiet("Nothing is waiting on you.")
            } else {
                ForEach(model.needsYou) { item in
                    // Tapping the card outside its answers opens its thread, as its Open does.
                    AttentionCard(item: item, busy: answering.contains(item.id), failure: failures[item.id], overview: true)
                        .contentShape(.rect)
                        .onTapGesture { navigator.open(projects.route(item)) }
                }
            }
        }
        column("Running now", count: model.runningCount) {
            if model.running.isEmpty && model.automationsRunning.isEmpty {
                quiet("Nothing is running.")
            }
            // One list per kind under its quiet head, a rule above each row.
            if !model.running.isEmpty {
                head("Threads", count: model.running.count)
                ForEach(model.running) { row in VStack(spacing: 0) { SHHairline(); runningButton(row) } }
            }
            if !model.automationsRunning.isEmpty {
                head("Automations", count: model.automationsRunning.count)
                ForEach(model.automationsRunning) { row in
                    VStack(spacing: 0) {
                        if let run = row.run {
                            SHHairline()
                            // The board's row: the run's name, then what it does and where.
                            Button { navigator.open(.thread(run.agentRef)) } label: {
                                SHOverviewRow(row.name, detail: [row.stateWord.sentenceCased, row.place, row.hostTag].compactMap { $0 }.joined(separator: " · "),
                                              detailMono: false)
                                    .equatable()
                            }
                            .buttonStyle(.shRow(radius: 0))
                        }
                    }
                }
            }
        }
        column("Finished", count: model.finished.count) {
            if model.finished.isEmpty {
                quiet("Nothing has finished yet.")
            } else {
                // A list a day, each row with the time it finished.
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(FleetFinishedDay.days(model.finished, now: context.date)) { day in
                            head(day.title, count: nil)
                            ForEach(day.rows) { row in VStack(spacing: 0) { SHHairline(); finishedButton(row, now: context.date) } }
                        }
                    }
                }
            }
        }
    }

    /// A running thread: its state, title and clock, and what it does now.
    private func runningButton(_ row: FleetThreadRow) -> some View {
        let time: SHOverviewRow.Time = if case .elapsed(let since)? = row.clock { .elapsed(since: Date(milliseconds: since)) } else { .none }
        return Button { navigator.open(.thread(row.ref.agentRef)) } label: {
            SHOverviewRow(row.title, detail: row.now, time: time, dimmed: row.offline)
                .equatable()
        }
        .buttonStyle(.shRow(radius: 0))
        .contextMenu { ThreadRowMenu(thread: row.ref.agentRef) }
    }

    /// A finished thread: a check (a cross for a failed last turn), its title over how it ended,
    /// and when it finished.
    private func finishedButton(_ row: FleetThreadRow, now: Date) -> some View {
        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
            SHOverviewRow(row.title, detail: row.failed ? "Failed · \(row.hostName)" : row.detail, detailMono: false,
                          detailTone: row.failed ? .failed : nil,
                          time: row.lastMoved.map { .text(FleetFinishedDay.stamp($0, now: now)) } ?? .none, dimmed: row.offline)
                .equatable()
        }
        .buttonStyle(.shRow(radius: 0))
        .contextMenu { ThreadRowMenu(thread: row.ref.agentRef) }
    }

    /// A column under its head; Needs you's is `lanternText` (iPadOverview).
    private func column(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            SHListHeader(title, attention: title == "Needs you" && count > 0, count: count)
                .accessibilityElement(children: .combine)
            content()
        }
        .frame(minWidth: MobileLayout.overviewColumnMinWidth, maxWidth: .infinity, alignment: .topLeading)
    }

    /// A list's quiet head ("Threads  3", "Today"): 13/500 in secondary.
    private func head(_ title: String, count: Int?) -> some View {
        HStack(spacing: SH.Space.s) {
            Text(title).font(.sh(.caption, weight: .medium)).foregroundStyle(Color.sh.textSecondary)
            if let count { Text("\(count)").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
        }
        .padding(.horizontal, SH.Space.xs)
        .padding(.top, SH.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
            .padding(.horizontal, SH.Space.l)
            .shCard(radius: SHListMetrics.cardRadius)
    }
}

/// A running thread's glyph (iPadOverview, iPadHosts): a dot, the branch while its
/// subagents work, or its state's dot while it waits on you.
enum RunningGlyph {
    static func of(_ row: FleetThreadRow) -> SHListRow.Leading {
        guard row.status == .working else { return .state(AgentState(row.status)) }
        return row.subagents > 0 ? .symbol(SHGlyph.gitBranch.symbolName, .running) : .glyph(.running)
    }
}

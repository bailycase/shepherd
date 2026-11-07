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
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        Group {
            if hosts.hosts.isEmpty {
                NoHostsState().frame(maxHeight: .infinity)
            } else if model.overviewIsEmpty {
                SHEmptyState(Text("No thread selected"), message: "Pick a thread in the sidebar, or start a new one.") {
                    Button("New thread") { NewThreadHooks.open(navigator: navigator) }.buttonStyle(.sh(.primary))
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    Group {
                        // Side by side when three columns fit; stacked in a narrow window or at large text.
                        if !typeSize.isAccessibilitySize, width >= MobileLayout.overviewColumnMinWidth * 3 + MobileLayout.blockSpacing * 2 + MobileLayout.gutter * 2 {
                            HStack(alignment: .top, spacing: MobileLayout.blockSpacing) {
                                OverviewColumns(model: model, answering: feed.answering, failures: feed.failures)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                                OverviewColumns(model: model, answering: feed.answering, failures: feed.failures)
                            }
                        }
                    }
                    .padding(MobileLayout.gutter)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .refreshable {
                    hosts.retryAll()
                    await feed.refresh()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.sh.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        // The board's head: "Overview" leading, the summary beside it.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Text("Overview").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                    if !model.hosts.isEmpty {
                        Text(model.summary).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
                Button("New thread", systemImage: "plus") { NewThreadHooks.open(navigator: navigator) }
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
                    AttentionCard(item: item, busy: answering.contains(item.id), failure: failures[item.id])
                        .contentShape(.rect)
                        .onTapGesture { navigator.open(projects.route(item)) }
                }
            }
        }
        column("Running now", count: model.runningCount) {
            if model.running.isEmpty && model.automationsRunning.isEmpty {
                quiet("Nothing is running.")
            }
            // One card per kind, each under its caption band.
            if !model.running.isEmpty {
                SHListCard {
                    SHCaptionBand("Threads · \(model.running.count)")
                    ForEach(model.running) { row in runningButton(row) }
                }
            }
            if !model.automationsRunning.isEmpty {
                SHListCard {
                    SHCaptionBand("Automations · \(model.automationsRunning.count)")
                    ForEach(model.automationsRunning) { row in
                        if let run = row.run {
                            // The board's row: the bolt in its run's state, what it does and where.
                            Button { navigator.open(.thread(run.agentRef)) } label: {
                                SHOverviewRow(row.name, detail: [row.stateWord, row.place, row.hostTag].compactMap { $0 }.joined(separator: " · "),
                                              leading: .symbol("bolt", row.runStatus == .blocked ? .attention : .running))
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
                // One card, a band per day, each row with the time it finished.
                TimelineView(.everyMinute) { context in
                    SHListCard {
                        ForEach(FleetFinishedDay.days(model.finished, now: context.date)) { day in
                            SHCaptionBand(day.title)
                            ForEach(day.rows) { row in finishedButton(row, now: context.date) }
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
            SHOverviewRow(row.title, detail: row.now, leading: RunningGlyph.of(row), time: time, dimmed: row.offline)
                .equatable()
        }
        .buttonStyle(.shRow(radius: 0))
        .contextMenu { ThreadRowMenu(thread: row.ref.agentRef) }
    }

    /// A finished thread: a check (a cross for a failed last turn), its title over how it ended,
    /// and when it finished.
    private func finishedButton(_ row: FleetThreadRow, now: Date) -> some View {
        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
            SHOverviewRow(row.title, detail: row.failed ? "failed · \(row.hostName)" : row.detail, detailMono: false,
                          leading: row.failed ? .symbol("xmark", .failed) : .symbol("checkmark", .done),
                          time: row.lastMoved.map { .text(FleetFinishedDay.stamp($0, now: now)) } ?? .none, dimmed: row.offline)
                .equatable()
        }
        .buttonStyle(.shRow(radius: 0))
        .contextMenu { ThreadRowMenu(thread: row.ref.agentRef) }
    }

    /// A column under its head; Needs you's is `lanternText` (iPadOverview).
    private func column(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        let tint = title == "Needs you" && count > 0 ? Color.sh.lanternText : Color.sh.textTertiary
        return VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            HStack(spacing: SH.Space.s) {
                Text(title).font(.sh(.micro)).textCase(.uppercase).tracking(SHTextStyle.micro.size * 0.06)
                    .foregroundStyle(tint).lineLimit(1)
                Spacer(minLength: SH.Space.xs)
                Text("\(count)").font(.sh(.micro)).foregroundStyle(tint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, SH.Space.xs)
            content()
        }
        .frame(minWidth: MobileLayout.overviewColumnMinWidth, maxWidth: .infinity, alignment: .topLeading)
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

/// A running thread's glyph (iPadOverview, iPadHosts): the spinner, the branch while its
/// subagents work, or its state's dot while it waits on you.
enum RunningGlyph {
    static func of(_ row: FleetThreadRow) -> SHListRow.Leading {
        guard row.status == .working else { return .state(AgentState(row.status)) }
        return row.subagents > 0 ? .symbol(SHGlyph.gitBranch.symbolName, .running) : .glyph(.running)
    }
}

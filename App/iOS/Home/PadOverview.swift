import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// The iPad detail with no thread selected (iPadOverview board; home track): Needs you with the
/// answers that fit in place, what runs now, and what finished, side by side when there is room.
struct PadOverview: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        Group {
            if model.hosts.isEmpty {
                NoHostsState().frame(maxHeight: .infinity)
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
        .background(Color.nw.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        // The board's head: "Overview" leading, the summary beside it.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                    Text("Overview").font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary)
                    if !model.hosts.isEmpty {
                        Text(model.summary).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
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

    var body: some View {
        column("Needs you", count: model.needsYou.count) {
            if model.needsYou.isEmpty {
                quiet("Nothing is waiting on you.")
            } else {
                ForEach(model.needsYou) { item in
                    AttentionCard(item: item, busy: answering.contains(item.id), failure: failures[item.id])
                }
            }
        }
        column("Running now", count: model.runningCount) {
            if model.running.isEmpty && model.automationsRunning.isEmpty {
                quiet("Nothing is running.")
            }
            // One card per kind, each under its caption band.
            if !model.running.isEmpty {
                NWListCard {
                    NWCaptionBand("Threads · \(model.running.count)")
                    ForEach(model.running) { row in runningButton(row) }
                }
            }
            if !model.automationsRunning.isEmpty {
                NWListCard {
                    NWCaptionBand("Automations · \(model.automationsRunning.count)")
                    ForEach(model.automationsRunning) { row in
                        if let run = row.run {
                            Button { navigator.open(.thread(run.agentRef)) } label: { AutomationRow(row: row).equatable() }
                                .buttonStyle(.nwRow(radius: 0))
                        }
                    }
                }
            }
        }
        column("Finished", count: model.finished.count) {
            if model.finished.isEmpty {
                quiet("Nothing has finished yet.")
            } else {
                // Under a band per day, each with the time it finished.
                TimelineView(.everyMinute) { context in
                    VStack(spacing: MobileLayout.blockSpacing) {
                        ForEach(FleetFinishedDay.days(model.finished, now: context.date)) { day in
                            NWListCard {
                                NWCaptionBand(day.title)
                                ForEach(day.rows) { row in finishedButton(row, now: context.date) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A running thread: its state, title and clock, and what it does now.
    private func runningButton(_ row: FleetThreadRow) -> some View {
        let time: NWOverviewRow.Time = if case .elapsed(let since)? = row.clock { .elapsed(since: Date(milliseconds: since)) } else { .none }
        return Button { navigator.open(.thread(row.ref.agentRef)) } label: {
            NWOverviewRow(row.title, detail: row.now, leading: .state(AgentState(row.status)), time: time, dimmed: row.offline)
                .equatable()
        }
        .buttonStyle(.nwRow(radius: 0))
        .contextMenu { OpenInNewWindowButton(thread: row.ref.agentRef) }
    }

    /// A finished thread: a check (a cross for a failed last turn), its title over how it ended,
    /// and when it finished.
    private func finishedButton(_ row: FleetThreadRow, now: Date) -> some View {
        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
            NWOverviewRow(row.title, detail: row.failed ? "failed · \(row.hostName)" : row.detail, detailMono: false,
                          leading: row.failed ? .symbol("xmark", .failed) : .symbol("checkmark", .done),
                          time: row.lastMoved.map { .text(FleetFinishedDay.stamp($0, now: now)) } ?? .none, dimmed: row.offline)
                .equatable()
        }
        .buttonStyle(.nwRow(radius: 0))
        .contextMenu { OpenInNewWindowButton(thread: row.ref.agentRef) }
    }

    private func column(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            NWSectionHeader(title, count: count)
                .padding(.horizontal, NW.Space.xs)
            content()
        }
        .frame(minWidth: MobileLayout.overviewColumnMinWidth, maxWidth: .infinity, alignment: .topLeading)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.nw(.caption))
            .foregroundStyle(Color.nw.textTertiary)
            .frame(maxWidth: .infinity, minHeight: NW.Height.touch, alignment: .leading)
            .padding(.horizontal, NW.Space.l)
            .nwCard(radius: NWListMetrics.cardRadius)
    }
}

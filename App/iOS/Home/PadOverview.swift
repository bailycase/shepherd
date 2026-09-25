import SwiftUI
import ShepherdUI
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
        .navigationSubtitle(model.hosts.isEmpty ? "" : model.summary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        column("Running now", count: model.running.count + model.automationsRunning.count) {
            if model.running.isEmpty && model.automationsRunning.isEmpty {
                quiet("Nothing is running.")
            }
            if !model.running.isEmpty {
                NWListCard {
                    ForEach(model.running) { row in threadButton(row) }
                }
            }
            if !model.automationsRunning.isEmpty {
                NWListCard {
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
                NWListCard {
                    ForEach(model.finished) { row in threadButton(row) }
                }
            }
        }
    }

    private func threadButton(_ row: FleetThreadRow) -> some View {
        Button { navigator.open(.thread(row.ref.agentRef)) } label: { ThreadRow(row: row, chevron: false).equatable() }
            .buttonStyle(.nwRow(radius: 0))
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

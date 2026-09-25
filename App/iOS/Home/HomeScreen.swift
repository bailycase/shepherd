import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The iPhone Home tab's root (MobileAgents board; home track): Automations and More, hosts that
/// are not connected with Retry, a short Needs you list, and Recents across every host.
struct HomeScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                if model.hosts.isEmpty {
                    NoHostsState()
                } else {
                    HomeSections(model: model, selected: navigator.selectedThread)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .refreshable {
            hosts.retryAll()
            await feed.refresh()
        }
        .task { await feed.watch() }
        .navigationTitle("Shepherd")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
                Button("New thread", systemImage: "square.and.pencil") { NewThreadHooks.open(navigator: navigator) }
                    .disabled(model.hosts.isEmpty)
            }
        }
    }
}

/// Home's sections, in the board's order.
private struct HomeSections: View {
    let model: FleetModel
    let selected: AgentRef?
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NWListCard {
            destination("Automations", symbol: "bolt", trailing: model.automations.isEmpty ? .none : .value(String(model.automations.count)), route: .automations)
            destination("More", symbol: "ellipsis", trailing: model.offlineSummary.map { .alert($0) } ?? .none, route: .more)
        }
        if !model.offlineHosts.isEmpty {
            NWListCard {
                ForEach(model.offlineHosts) { card in HostNotice(card: card).equatable() }
            }
        }
        if !model.needsYou.isEmpty {
            section("Needs you", attention: true, count: model.needsYou.count) {
                NWListCard {
                    ForEach(model.needsYou.prefix(HomeLimits.needsYou)) { item in
                        Button { navigator.open(item.route) } label: { AttentionRow(item: item).equatable() }
                            .buttonStyle(.nwRow(radius: 0))
                    }
                    Button { navigator.open(.home(.needsYou)) } label: {
                        Text(model.needsYou.count > HomeLimits.needsYou ? "See all \(model.needsYou.count)" : "Answer in Needs you")
                            .font(.nw(.caption, weight: .medium))
                            .foregroundStyle(Color.nw.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: NW.Height.touch)
                    }
                    .buttonStyle(.nwRow(radius: 0))
                }
            }
        }
        section("Recents", count: nil) {
            if model.recents.isEmpty {
                NWListCard { EmptyRecents() }
            } else {
                NWListCard {
                    ForEach(model.recents.prefix(HomeLimits.recents)) { row in
                        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
                            ThreadRow(row: row, selected: row.ref.agentRef == selected).equatable()
                        }
                        .buttonStyle(.nwRow(radius: 0))
                    }
                    if model.recents.count > HomeLimits.recents {
                        Button { navigator.open(.home(.recents)) } label: {
                            Text("Show all recents")
                                .font(.nw(.caption, weight: .medium))
                                .foregroundStyle(Color.nw.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: NW.Height.touch)
                        }
                        .buttonStyle(.nwRow(radius: 0))
                    }
                }
            }
        }
    }

    private func destination(_ title: String, symbol: String, trailing: NWListRow.Trailing, route: HomeRoute) -> some View {
        Button { navigator.open(.home(route)) } label: {
            NWListRow(title, leading: .symbol(symbol), trailing: trailing)
        }
        .buttonStyle(.nwRow(radius: 0))
    }

    private func section(_ title: String, attention: Bool = false, count: Int?,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            NWListHeader(title, attention: attention, count: count)
            content()
        }
    }
}

/// No threads on any connected host yet.
struct EmptyRecents: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text("No threads yet").font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textPrimary)
            Text("Start one on any host; it shows here with the host it runs on.")
                .nwText(.caption).foregroundStyle(Color.nw.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("New thread", systemImage: "square.and.pencil") { NewThreadHooks.open(navigator: navigator) }
                .buttonStyle(.nw(.secondary))
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// No hosts yet: the one thing to do is add one.
struct NoHostsState: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NWEmptyState(Text("Add a host"), message: "Connect to a Mac running Shepherd to see its threads.") {
            Button("Add host") { navigator.present(.settings(.host(nil))) }.buttonStyle(.nw(.primary))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MobileLayout.sectionSpacing)
    }
}

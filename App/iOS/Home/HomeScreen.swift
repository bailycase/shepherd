import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The iPhone Home tab's root (MobileAgents board; home track): Automations and More, hosts that
/// are not connected with Retry, a short Needs you list, the Mac sidebar's Working, Done and
/// Pinned (`SidebarThreads`), and Recents across every host. A row's long press is the Mac's row
/// menu (`ThreadRowMenu`).
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
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileProjects.self) private var projects

    var body: some View {
        let designs = MobileDesigns.of(hosts).model
        let groups = SidebarThreads.of(hosts).groups(model)
        NWListCard {
            // Designs, while a host serves them (MobileAgents: between Missions and Automations).
            if designs.available {
                Button { navigator.open(.designs(.list)) } label: {
                    NWListRow("Designs", leading: .symbol("pencil.tip"), trailing: designs.count.map { .value($0) } ?? .none)
                }
                .buttonStyle(.nwRow(radius: 0))
            }
            // Always listed: with no host serving Projects, its screen says why.
            Button { navigator.open(.projects(.list)) } label: {
                NWListRow("Projects", leading: .symbol("square.stack.3d.up"), trailing: projectsTrailing)
            }
            .buttonStyle(.nwRow(radius: 0))
            destination("Automations", symbol: "bolt", trailing: model.automations.isEmpty ? .none : .value(String(model.automations.count)), route: .automations)
            destination("More", symbol: "ellipsis", trailing: model.offlineSummary.map { .alert($0) } ?? .none, route: .more)
        }
        if !model.offlineHosts.isEmpty {
            NWListCard {
                ForEach(model.offlineHosts) { card in HostNotice(card: card).equatable() }
            }
        }
        if !groups.needsYou.isEmpty {
            section("Needs you", attention: true, count: groups.needsYou.count) {
                NWListCard {
                    ForEach(groups.needsYou.prefix(HomeLimits.needsYou)) { item in
                        attentionRow(item)
                    }
                    Button { navigator.open(.home(.needsYou)) } label: {
                        Text(groups.needsYou.count > HomeLimits.needsYou ? "See all \(groups.needsYou.count)" : "Answer in Needs you")
                            .font(.nw(.caption, weight: .medium))
                            .foregroundStyle(Color.nw.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: NW.Height.touch)
                    }
                    .buttonStyle(.nwRow(radius: 0))
                }
            }
        }
        // The Mac's Working, Done and Pinned, in its order (docs/design/sidebar.md).
        if !groups.working.isEmpty {
            section("Working", count: groups.working.count) {
                NWListCard { ForEach(groups.working) { row in threadRow(row) } }
            }
        }
        if !groups.done.isEmpty {
            section("Done", count: groups.done.count, trailing: MarkAllSeenChip(rows: groups.done)) {
                NWListCard { ForEach(groups.done) { row in threadRow(row) } }
            }
        }
        if !groups.pinned.isEmpty {
            section("Pinned", count: groups.pinned.count) {
                NWListCard {
                    ForEach(groups.pinned) { pinned in
                        VStack(spacing: 0) {
                            switch pinned {
                            case .thread(let row): threadRow(row)
                            case .attention(let item): attentionRow(item)
                            }
                        }
                    }
                }
            }
        }
        section("Recents", count: nil) {
            if groups.recents.isEmpty {
                NWListCard { EmptyRecents() }
            } else {
                NWListCard {
                    ForEach(groups.recents.prefix(HomeLimits.recents)) { row in
                        threadRow(row)
                    }
                    if groups.recents.count > HomeLimits.recents {
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

    private var projectsTrailing: NWListRow.Trailing {
        let rows = projects.rows
        let needsYou = rows.reduce(0) { $0 + $1.needsYou }
        if needsYou > 0 { return .alert("\(needsYou) needs you") }
        return rows.isEmpty ? .none : .value(String(rows.count))
    }

    private func destination(_ title: String, symbol: String, trailing: NWListRow.Trailing, route: HomeRoute) -> some View {
        Button { navigator.open(.home(route)) } label: {
            NWListRow(title, leading: .symbol(symbol), trailing: trailing)
        }
        .buttonStyle(.nwRow(radius: 0))
    }

    private func section(_ title: String, attention: Bool = false, count: Int?, trailing: MarkAllSeenChip? = nil,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            HStack(alignment: .center, spacing: NW.Space.s) {
                NWListHeader(title, attention: attention, count: count)
                trailing
            }
            content()
        }
    }

    /// A thread or design row; a design's row keeps its own route and has no thread menu.
    private func threadRow(_ row: FleetThreadRow) -> some View {
        Button { navigator.open(row.route) } label: {
            ThreadRow(row: row, selected: row.ref.agentRef == selected).equatable()
        }
        .buttonStyle(.nwRow(radius: 0))
        .contextMenu { if row.design == nil { ThreadRowMenu(thread: row.ref.agentRef) } }
    }

    private func attentionRow(_ item: FleetAttention) -> some View {
        Button { navigator.open(projects.route(item)) } label: { AttentionRow(item: item).equatable() }
            .buttonStyle(.nwRow(radius: 0))
            .contextMenu { ThreadRowMenu(thread: item.ref.agentRef) }
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

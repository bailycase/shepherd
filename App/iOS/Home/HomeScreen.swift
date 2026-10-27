import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The iPhone Home tab's root, the inbox (DuoClosedHome board; home track): hosts that are not
/// connected with Retry, a short Needs you list, the Mac sidebar's Working, Done and Pinned
/// (`SidebarThreads`), and Recents across every host. Designs, Projects and Automations are
/// tabs beside it (`PhoneShell`). A row's long press is the Mac's row menu (`ThreadRowMenu`).
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
        .background(Color.sh.bgWindow)
        .refreshable {
            hosts.retryAll()
            await feed.refresh()
        }
        .task { await feed.watch() }
        .navigationTitle("Shepherd")
        // New thread is the screen's one prominent action and the last to overflow; on the Duo's
        // closed display both join the system column above the tabs (platform-iphone-duo.md).
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { NewThreadHooks.open(navigator: navigator) } label: { Label("New thread", systemImage: "square.and.pencil") }
                    .buttonStyle(.glassProminent)
                    .tint(Color.sh.lantern)
                    .disabled(model.hosts.isEmpty)
            }
            .visibilityPriority(.high)
            ToolbarItem(placement: .topBarTrailing) {
                Button { SearchHooks.open(navigator: navigator) } label: { Label("Search", systemImage: "magnifyingglass") }
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
        let groups = SidebarThreads.of(hosts).groups(model)
        if !model.offlineHosts.isEmpty {
            SHListCard {
                ForEach(model.offlineHosts) { card in HostNotice(card: card).equatable() }
            }
        }
        if !groups.needsYou.isEmpty {
            section("Needs you", attention: true, count: groups.needsYou.count) {
                SHListCard {
                    ForEach(groups.needsYou.prefix(HomeLimits.needsYou)) { item in
                        attentionRow(item)
                    }
                    Button { navigator.open(.home(.needsYou)) } label: {
                        Text(groups.needsYou.count > HomeLimits.needsYou ? "See all \(groups.needsYou.count)" : "Answer in Needs you")
                            .font(.sh(.caption, weight: .medium))
                            .foregroundStyle(Color.sh.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                    }
                    .buttonStyle(.shRow(radius: 0))
                }
            }
        }
        // The Mac's Working, Done and Pinned, in its order (docs/design/sidebar.md).
        if !groups.working.isEmpty {
            section("Working", count: groups.working.count) {
                SHListCard { ForEach(groups.working) { row in threadRow(row) } }
            }
        }
        if !groups.done.isEmpty {
            section("Done", count: groups.done.count, trailing: MarkAllSeenChip(rows: groups.done)) {
                SHListCard { ForEach(groups.done) { row in threadRow(row) } }
            }
        }
        if !groups.pinned.isEmpty {
            section("Pinned", count: groups.pinned.count) {
                SHListCard {
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
                SHListCard { EmptyRecents() }
            } else {
                SHListCard {
                    ForEach(groups.recents.prefix(HomeLimits.recents)) { row in
                        threadRow(row)
                    }
                    if groups.recents.count > HomeLimits.recents {
                        Button { navigator.open(.home(.recents)) } label: {
                            Text("Show all recents")
                                .font(.sh(.caption, weight: .medium))
                                .foregroundStyle(Color.sh.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                        }
                        .buttonStyle(.shRow(radius: 0))
                    }
                }
            }
        }
    }

    private func section(_ title: String, attention: Bool = false, count: Int?, trailing: MarkAllSeenChip? = nil,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            HStack(alignment: .center, spacing: SH.Space.s) {
                SHListHeader(title, attention: attention, count: count)
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
        .buttonStyle(.shRow(radius: 0))
        .contextMenu { if row.design == nil { ThreadRowMenu(thread: row.ref.agentRef) } }
    }

    private func attentionRow(_ item: FleetAttention) -> some View {
        Button { navigator.open(projects.route(item)) } label: { AttentionRow(item: item).equatable() }
            .buttonStyle(.shRow(radius: 0))
            .contextMenu { ThreadRowMenu(thread: item.ref.agentRef) }
    }
}

/// No threads on any connected host yet.
struct EmptyRecents: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text("No threads yet").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
            Text("Start one on any host; it shows here with the host it runs on.")
                .shText(.caption).foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("New thread", systemImage: "square.and.pencil") { NewThreadHooks.open(navigator: navigator) }
                .buttonStyle(.sh(.secondary))
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// No hosts yet: the one thing to do is add one.
struct NoHostsState: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        SHEmptyState(Text("Add a host"), message: "Connect to a Mac running Shepherd to see its threads.") {
            Button("Add host") { navigator.present(.settings(.host(nil))) }.buttonStyle(.sh(.primary))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MobileLayout.sectionSpacing)
    }
}

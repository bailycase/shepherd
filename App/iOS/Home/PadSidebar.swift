import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The iPad sidebar (iPadSidebar board; home track): New thread, Automations and More, Needs you
/// with each item's reason, Recents with their hosts, and a footer with the hosts and Settings.
struct PadSidebar: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        let selected = navigator.selectedThread
        let pushed = navigator.padPath.last
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SidebarItem("New thread", symbol: "plus.circle") { NewThreadHooks.open(navigator: navigator) }
                    .disabled(model.hosts.isEmpty)
                SidebarItem("Automations", symbol: "bolt", selected: pushed == .home(.automations),
                            trailing: model.automations.isEmpty ? .none : .value(String(model.automations.count))) {
                    navigator.open(.home(.automations))
                }
                SidebarItem("More", symbol: "ellipsis", selected: pushed == .home(.more),
                            trailing: model.offlineSummary.map { .alert($0) } ?? .none) {
                    navigator.open(.home(.more))
                }
                if !model.needsYou.isEmpty {
                    SidebarHeader(title: "Needs you", attention: true, count: model.needsYou.count) {
                        navigator.open(.home(.needsYou))
                    }
                    ForEach(model.needsYou) { item in
                        Button { navigator.open(item.route) } label: {
                            AttentionRow(item: item, selected: item.runID == nil && item.ref.agentRef == selected, compact: true)
                                .equatable()
                                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                        }
                        .buttonStyle(.nwRow(radius: NW.Radius.m))
                    }
                }
                if !model.recents.isEmpty {
                    SidebarHeader(title: "Recents")
                    ForEach(model.recents) { row in
                        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
                            ThreadRow(row: row, selected: row.ref.agentRef == selected, compact: true)
                                .equatable()
                                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                        }
                        .buttonStyle(.nwRow(radius: NW.Radius.m))
                    }
                }
            }
            .padding(.horizontal, NW.Space.m)
            .padding(.bottom, NW.Space.l)
        }
        .background(Color.nw.bgBase)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(count: model.hosts.count, offline: model.offlineCount, names: model.hostNames)
        }
        .task { await feed.watch() }
        .navigationTitle("Shepherd")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
            }
        }
    }
}

/// A destination at the sidebar's top.
private struct SidebarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let trailing: NWListRow.Trailing
    let action: () -> Void

    init(_ title: String, symbol: String, selected: Bool = false, trailing: NWListRow.Trailing = .none,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            NWListRow(title, leading: .symbol(symbol), trailing: trailing, chevron: false, selected: selected)
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        }
        .buttonStyle(.nwRow(radius: NW.Radius.m))
    }
}

/// A section's head in the sidebar; Needs you's opens the inbox.
private struct SidebarHeader: View {
    let title: String
    var attention = false
    var count: Int?
    var action: (() -> Void)?

    var body: some View {
        // A touch tall, so Needs you's header is a full target; the text sits on its bottom.
        let header = NWListHeader(title, attention: attention, count: count)
            .padding(.horizontal, NW.Space.m)
            .padding(.bottom, NW.Space.xs)
            .frame(minHeight: NW.Height.touch, alignment: .bottom)
        if let action {
            Button(action: action) { header.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Needs you")
        } else {
            header
        }
    }
}

/// The sidebar's foot: the hosts (opening Settings ▸ Hosts) and Settings.
private struct SidebarFooter: View, Equatable {
    let count: Int
    let offline: Int
    let names: String
    @Environment(MobileNavigator.self) private var navigator

    static func == (a: SidebarFooter, b: SidebarFooter) -> Bool {
        a.count == b.count && a.offline == b.offline && a.names == b.names
    }

    var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            NWHairline()
            HStack(spacing: NW.Space.m) {
                Button { navigator.open(.settings(.hosts)) } label: {
                    HStack(spacing: NW.Space.m) {
                        Image(systemName: "desktopcomputer")
                            .font(.nw(.ui, weight: .medium))
                            .foregroundStyle(offline > 0 ? nw.failed : nw.textSecondary)
                            .frame(width: NWListMetrics.leadingWidth)
                        VStack(alignment: .leading, spacing: NW.Space.xxs) {
                            Text(count == 0 ? "No hosts" : offline > 0 ? "\(offline) of \(count) offline" : "\(count) connected")
                                .font(.nw(.ui, weight: .medium))
                                .foregroundStyle(offline > 0 ? nw.failed : nw.textPrimary)
                            if !names.isEmpty {
                                Text(names).font(.nw(.mono)).foregroundStyle(nw.textTertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: NW.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hosts")
                .accessibilityValue(offline > 0 ? "\(offline) offline" : "\(count) connected")
                Button { navigator.open(.settings(.root)) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.nw(.ghost))
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, NW.Space.l)
            .padding(.vertical, NW.Space.xs)
        }
        .background(nw.bgBase)
    }
}

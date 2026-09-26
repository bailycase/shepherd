import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The iPad sidebar (iPadThread, iPadSidebar, iPadHosts boards; home track): New thread,
/// Automations and More (which expands in place to Hosts and Extensions), Needs you with each
/// item's reason, Recents with their hosts, and a footer with the hosts and Settings.
struct PadSidebar: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    /// More's sub-rows show (iPadHosts); kept per window.
    @SceneStorage("shepherd.ios.sidebar.moreExpanded") private var moreExpanded = false

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        let selected = navigator.selectedThread
        let pushed = navigator.padPath.last
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SidebarItem("New thread", leading: .badge("plus")) { NewThreadHooks.open(navigator: navigator) }
                    .disabled(model.hosts.isEmpty)
                SidebarItem("Automations", leading: .symbol("bolt"), selected: pushed == .home(.automations),
                            trailing: model.automations.isEmpty ? .none : .value(String(model.automations.count))) {
                    navigator.open(.home(.automations))
                }
                // More expands in place; folded, it carries the offline summary.
                SidebarItem("More", leading: .symbol(moreExpanded ? "chevron.down" : "chevron.right"),
                            trailing: moreExpanded ? .none : model.offlineSummary.map { .alert($0) } ?? .none) {
                    withNWAnimation(.disclosure) { moreExpanded.toggle() }
                }
                .accessibilityValue(moreExpanded ? "Expanded" : "Collapsed")
                if moreExpanded {
                    // The sub-rows' content sits further in; their selection keeps the full width.
                    Group {
                        SidebarItem("Hosts", leading: .symbol("desktopcomputer"), selected: pushed == .home(.more),
                                    trailing: model.offlineCount > 0 ? .alert("\(model.offlineCount) offline") : .none,
                                    indent: MobileLayout.sidebarSubrowIndent) {
                            navigator.open(.home(.more))
                        }
                        if !model.hosts.isEmpty {
                            SidebarItem(SettingsPage.pi.title, leading: .symbol(SettingsPage.pi.symbol),
                                        selected: pushed == .settings(SettingsPage.pi.route),
                                        indent: MobileLayout.sidebarSubrowIndent) {
                                navigator.open(.settings(SettingsPage.pi.route))
                            }
                        }
                    }
                    .nwTransition(.content)
                }
                if !model.needsYou.isEmpty {
                    SidebarHeader(title: "Needs you", attention: true, count: model.needsYou.count) {
                        navigator.open(.home(.needsYou))
                    }
                    ForEach(model.needsYou) { item in
                        Button { navigator.open(item.route) } label: {
                            // A subagent's item marks while its run is open over the thread.
                            AttentionRow(item: item, selected: pushed == item.route || (item.runID == nil && item.ref.agentRef == selected),
                                         compact: true)
                                .equatable()
                                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                        }
                        .buttonStyle(.nwRow(radius: NW.Radius.m))
                        .contextMenu { OpenInNewWindowButton(thread: item.ref.agentRef) }
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
                        .contextMenu { OpenInNewWindowButton(thread: row.ref.agentRef) }
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
        // A page under More, opened from elsewhere, shows its row.
        .onChange(of: pushed, initial: true) { _, pushed in
            if pushed == .home(.more) || pushed == .settings(SettingsPage.pi.route), !moreExpanded { moreExpanded = true }
        }
        // The board's bar has no title: Search and the split view's Hide sidebar.
        .navigationTitle("Shepherd")
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
            }
        }
    }
}

/// A destination at the sidebar's top: a 44pt row.
private struct SidebarItem: View {
    let title: String
    let leading: NWListRow.Leading
    let selected: Bool
    let trailing: NWListRow.Trailing
    let indent: CGFloat
    let action: () -> Void

    init(_ title: String, leading: NWListRow.Leading, selected: Bool = false, trailing: NWListRow.Trailing = .none,
         indent: CGFloat = 0, action: @escaping () -> Void) {
        self.title = title
        self.leading = leading
        self.selected = selected
        self.trailing = trailing
        self.indent = indent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            NWListRow(title, leading: leading, trailing: trailing, chevron: false, selected: selected, compact: true, indent: indent)
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
        let header = NWListHeader(title, attention: attention, count: count, style: .sidebar)
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

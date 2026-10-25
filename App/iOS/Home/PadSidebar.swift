import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The iPad sidebar (iPadThread, iPadSidebar, iPadHosts boards; home track): New thread,
/// Designs (while a host serves them, DesignPad/), Automations and More (which expands in place
/// to Hosts and Extensions), Needs you with each item's reason, automation runs, then the Mac
/// sidebar's Working, Done (with Mark all seen) and Pinned (`SidebarThreads`), Recents with their
/// hosts and the designs among them, and a footer with the hosts and Settings. A thread row's
/// long press is the Mac's row menu (`ThreadRowMenu`).
struct PadSidebar: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    /// More's sub-rows show (iPadHosts); kept per window.
    @SceneStorage("shepherd.ios.sidebar.moreExpanded") private var moreExpanded = false
    @Environment(MobileProjects.self) private var projects

    private var projectsTrailing: NWListRow.Trailing {
        let needsYou = projects.rows.reduce(0) { $0 + $1.needsYou }
        if needsYou > 0 { return .alert("\(needsYou) needs you") }
        return projects.rows.isEmpty ? .none : .value(String(projects.rows.count))
    }

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        let designs = PadDesigns.of(hosts)
        let groups = SidebarThreads.of(hosts).groups(model)
        let recents = designs.recents(groups.recents)
        let selected = navigator.selectedThread
        let pushed = navigator.padPath.last
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SidebarItem("New thread", leading: .badge("plus")) { NewThreadHooks.open(navigator: navigator) }
                    .disabled(model.hosts.isEmpty)
                // The Design tool's destination, only while a host offers it (iPadSidebar).
                if designs.available {
                    SidebarItem("Designs", leading: .symbol("pencil.tip"), selected: pushed?.isPadDesign == true) {
                        PadDesignHooks.openList(navigator: navigator)
                    }
                }
                SidebarItem("Projects", leading: .symbol("square.stack.3d.up"), selected: pushed?.isProjects == true,
                            trailing: projectsTrailing) {
                    navigator.open(.projects(.list))
                }
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
                if !groups.needsYou.isEmpty {
                    SidebarHeader(title: "Needs you", attention: true, count: groups.needsYou.count) {
                        navigator.open(.home(.needsYou))
                    }
                    ForEach(groups.needsYou) { item in
                        attentionRow(item, pushed: pushed, selected: selected)
                    }
                }
                // Automation runs have their own group, never among Recents; its header opens the Automations screen.
                // A run waiting on you is in Needs you above, once: it is not counted or drawn here as well.
                let waiting = Set(model.needsYou.map(\.ref))
                let runs = model.automations.filter { row in row.run.map { !waiting.contains($0) } ?? false }
                if !runs.isEmpty {
                    SidebarHeader(title: "Automations", count: runs.count, hint: "Opens Automations") {
                        navigator.open(.home(.automations))
                    }
                    ForEach(runs) { row in
                        if let run = row.run {
                            Button { navigator.open(.thread(run.agentRef)) } label: {
                                AutomationRow(row: row, selected: run.agentRef == selected)
                                    .equatable()
                                    .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                            }
                            .buttonStyle(.nwRow(radius: NW.Radius.m))
                            .contextMenu { AutomationRunMenu(row: row) }
                        }
                    }
                }
                // The Mac's Working, Done and Pinned, in its order (docs/design/sidebar.md).
                if !groups.working.isEmpty {
                    SidebarHeader(title: "Working", count: groups.working.count)
                    ForEach(groups.working) { row in threadRow(row, selected: selected) }
                }
                if !groups.done.isEmpty {
                    HStack(alignment: .bottom, spacing: 0) {
                        SidebarHeader(title: "Done", count: groups.done.count)
                        MarkAllSeenChip(rows: groups.done)
                    }
                    ForEach(groups.done) { row in threadRow(row, selected: selected) }
                }
                if !groups.pinned.isEmpty {
                    SidebarHeader(title: "Pinned", count: groups.pinned.count)
                    ForEach(groups.pinned) { pinned in
                        VStack(spacing: 0) {
                            switch pinned {
                            case .thread(let row): threadRow(row, selected: selected)
                            case .attention(let item): attentionRow(item, pushed: pushed, selected: selected)
                            }
                        }
                    }
                }
                if !recents.isEmpty {
                    SidebarHeader(title: "Recents")
                    ForEach(recents) { recent in
                        // One view per row, whatever it holds.
                        VStack(spacing: 0) {
                            switch recent {
                            case .thread(let row):
                                threadRow(row, selected: selected)
                            case .design(let row):
                                Button { PadDesignHooks.open(row.ref, navigator: navigator) } label: {
                                    PadDesignRecentRow(row: row, selected: pushed == .padDesign(.design(row.ref)))
                                        .equatable()
                                        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                                }
                                .buttonStyle(.nwRow(radius: NW.Radius.m))
                                .contextMenu { PadDesignWindowButton(design: row.ref) }
                            }
                        }
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

    private func threadRow(_ row: FleetThreadRow, selected: AgentRef?) -> some View {
        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
            ThreadRow(row: row, selected: row.ref.agentRef == selected, compact: true)
                .equatable()
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        }
        .buttonStyle(.nwRow(radius: NW.Radius.m))
        .contextMenu { ThreadRowMenu(thread: row.ref.agentRef) }
    }

    private func attentionRow(_ item: FleetAttention, pushed: MobileRoute?, selected: AgentRef?) -> some View {
        Button { navigator.open(projects.route(item)) } label: {
            AttentionRow(item: item, selected: pushed == item.route || item.ref.agentRef == selected, compact: true)
                .equatable()
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        }
        .buttonStyle(.nwRow(radius: NW.Radius.m))
        .contextMenu { ThreadRowMenu(thread: item.ref.agentRef) }
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

/// A section's head in the sidebar; Needs you's opens the inbox, Automations' its screen.
private struct SidebarHeader: View {
    let title: String
    var attention = false
    var count: Int?
    var hint = "Opens Needs you"
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
                .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(hint)
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

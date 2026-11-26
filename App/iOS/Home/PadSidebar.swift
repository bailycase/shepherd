import SwiftUI
import ShepherdUI
import ShepherdRemote
import ShepherdProtocol
import ShepherdSidebar

/// The sidebar on the iPad and the iPhone Duo's inner display: the Mac's sidebar (iPadSidebar, DuoOpenThread, the Mac's
/// GXThread), drawn by the same components (`SHSidebar`, `SHSidebarDestination`, `SHSidebarSectionHeader`, `SHSidebarRow`) from
/// the same rows (`SidebarDerivation.lists`, `SidebarLists.items`): New thread, Designs, Automations and Issues & PRs, then Designs,
/// Projects, Automations, Needs you, Working, Done, Pinned and Recents with the threads a thread sent under it, and the footer
/// with the Fleet line and Settings. It floats as the boards' glass card. A thread row's long press is the Mac's row menu
/// (`ThreadRowMenu`).
struct PadSidebar: View {
    /// Sliding over the thread: the card is opaque there, since the thread shows through its glass.
    var overlays = false
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileProjects.self) private var projects

    private var settings: SettingsStore { SettingsStore.of(hosts) }

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let sidebar = SidebarThreads.of(hosts)
        let designs = PadDesigns.of(hosts)
        let automations = AutomationsStore.of(hosts)
        let forgeShown = ForgeEntry.available(hosts)
        let forge = ForgeStore.of(hosts)
        let pushed = navigator.padPath.last
        let pins = forgeShown ? forge.sidebarPins : (pins: [], hosts: [:])
        let listing = sidebar.listing(.init(
            selected: navigator.selectedThread.map { .remote(RemoteAgentRef(hostID: $0.host, agentID: $0.agent)) },
            designs: designs.available,
            projects: projects.rows.map { row in
                SidebarLogicalProject(ref: row.ref, name: row.name, hostName: row.owner, summary: row.summary.isEmpty ? nil : row.summary,
                                      needsYou: row.needsYou > 0, selected: pushed?.isProjects == true)
            },
            selectedAutomation: pushed == .home(.automations) ? automations.chosen : nil,
            forgePins: pins.pins, forgePinsProblem: forgeShown ? forge.pinsProblems.first?.message : nil,
            unreadRuns: automations.unreadRuns, unreadRunCounts: automations.unreadRunCounts,
            triggerStatuses: automations.triggerStatuses))
        let shown: MainDestination? = pushed?.isPadDesign == true ? .designs : pushed == .home(.automations) ? .automations
            : pushed?.isForge == true ? .forge : nil
        let destinations = SidebarDerivation.destinations(
            shown: shown, newThreadChord: "", designs: designs.available,
            automations: automations.unreadRuns.isEmpty ? .none : .count(automations.unreadRuns.count),
            forge: forgeShown ? forge.needsYou : 0)
        let fleetRows = settings.fleetRows
        SHSidebar(topBar: PadSidebarTopBar()) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: SHSidebarMetrics.rowSpacing) {
                        ForEach(destinations) { row in
                            SHSidebarDestination(row.title, icon: row.icon, selected: row.selected, child: row.child, trailing: row.trailing) {
                                open(row)
                            }
                            .equatable()
                            .accessibilityLabel(SidebarDerivation.accessibilityLabel(row))
                        }
                    }
                    .padding(.vertical, SHSidebarMetrics.destinationsPadding)
                    .padding(.horizontal, SHSidebarMetrics.listInset)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(listing.items) { item in
                            PadSidebarItem(item: item, forgeHosts: pins.hosts, done: listing.done)
                                .equatable()
                        }
                    }
                    .padding(.horizontal, SHSidebarMetrics.listInset)
                    .padding(.bottom, SH.Space.m)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable {
                hosts.retryAll()
                await feed.refresh()
            }
        } footer: {
            SHSidebarFooter(name: "", detail: fleetRows.isEmpty ? "" : "Fleet · \(FleetDeviceList.footer(fleetRows).detail)",
                            openDetail: { navigator.open(.settings(.fleet)) },
                            settings: { navigator.open(.settings(.root)) })
                .equatable()
        }
        .task { await feed.watch() }
        // The Fleet line's "1 asleep", read every so often while a Mac serves the fleet (the Fleet screen reads faster).
        .task(id: settings.showsFleet) {
            guard settings.showsFleet else { return }
            while !Task.isCancelled {
                await settings.fleet.refresh(settings.hosts)
                try? await Task.sleep(for: .seconds(MobileLayout.fleetFooterPoll))
            }
        }
        // Automations' unread dots and paused triggers, read while their rows show.
        .task(id: listing.items.contains { if case .automation = $0 { true } else { false } }) { await automations.watch() }
        .task(id: forge.sessionsKey) { if forgeShown { await forge.loadRepos() } }
        .background(overlays ? Color.sh.bgBase : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.xl))
        .padding(SHSidebarMetrics.panelInset)
    }

    private func open(_ row: SidebarDerivation.Destination) {
        guard case .page(let page) = row.target else { return }
        switch page {
        case .newThread: NewThreadHooks.open(navigator: navigator)
        case .designs: PadDesignHooks.openList(navigator: navigator)
        case .automations: navigator.open(.home(.automations))
        case .forge: navigator.open(.forge(.list))
        default: break
        }
    }
}

/// The 44pt top bar (the Mac's `SHSidebarTopBar`, with the touch client's own buttons): Search, More (Stop all working threads) and Hide
/// sidebar.
private struct PadSidebarTopBar: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        HStack(spacing: SHSidebarMetrics.topBarButtonGap) {
            Spacer(minLength: 0)
            Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
            StopAllWorkingMenu()
            Button("Hide sidebar", systemImage: "sidebar.left") { withSHAnimation(.pane) { navigator.padColumns = .detailOnly } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.shIcon(size: SH.Height.touch))
        .font(.sh(.ui))
        .imageScale(.large)
        .foregroundStyle(Color.sh.textSecondary)
        .padding(.trailing, SHSidebarMetrics.topBarTrailing)
        .frame(height: SH.Height.touch)
    }
}

/// One element of the sidebar's list, a single view whatever it shows (a lazy stack's fast path), redrawn only when its values change.
private struct PadSidebarItem: View, Equatable {
    let item: SidebarActivityItem
    let forgeHosts: [ForgeItemRef: UUID]
    let done: [SidebarListRow]
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    static func == (a: PadSidebarItem, b: PadSidebarItem) -> Bool {
        a.item == b.item && a.forgeHosts == b.forgeHosts && (!a.item.isDoneHeader || a.done == b.done)
    }

    var body: some View {
        let sidebar = SidebarThreads.of(hosts)
        VStack(spacing: 0) {
            switch item {
            case .header(let section, let count, let collapsed):
                SHSidebarSectionHeader(section.title, count: count, isExpanded: !collapsed,
                                       attention: section == .needsYou, pulse: section == .working,
                                       toggle: { sidebar.toggle(section) },
                                       markAllSeen: section == .done ? { sidebar.markSeen(done) } : nil)
            case .project(let project):
                Button { navigator.open(.projects(.project(project.ref))) } label: {
                    SHLeadProjectRow(project.name, selected: project.selected, summary: project.summary, needsYou: project.needsYou)
                        .equatable()
                }
                .buttonStyle(.plain)
            case .forgePin(let pin):
                forgePin(pin)
            case .forgePinsProblem(let message):
                SHBanner(.failed, title: "Pins unavailable", message: message, stacked: true) {
                    Button("Refresh") { Task { await ForgeStore.of(hosts).loadSidebars() } }.buttonStyle(.sh(.secondary))
                }
                .padding(.horizontal, SH.Space.s)
            case .automation(let automation, let expanded):
                automationRow(automation, expanded: expanded)
            case .row(let row):
                threadRow(row)
            }
        }
    }

    // MARK: Rows

    private func threadRow(_ row: SidebarListRow) -> some View {
        let sidebar = SidebarThreads.of(hosts)
        let fold = row.fold.map { fold in SHSidebarRow.Fold(open: fold.open) { sidebar.toggleFold(fold.key) } }
        return Button { open(row) } label: {
            SHSidebarRow(row.title, leading: row.leading, selected: row.selected, dimmed: row.offline, accessory: row.accessory,
                         hasGoal: row.hasGoal, nested: row.foldedUnder != nil, badge: row.pullRequest, elbow: row.fleetNested,
                         subtitle: row.subtitle, fold: fold, unseen: row.section == .done)
                .equatable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(row.selected ? .isSelected : [])
        .modifier(SentFoldAction(fold: row.fold))
        .contextMenu { PadSidebarRowMenu(row: row) }
    }

    private func automationRow(_ automation: SidebarAutomation, expanded: Bool?) -> some View {
        let key = automation.key
        let toggle = { SidebarThreads.of(hosts).toggleFold(SidebarLists.runGroupKey(key)) }
        return Button { AutomationsHooks.open(key, navigator: navigator) } label: {
            SHSidebarAutomationRow(automation.name, word: automation.word, tone: automation.tone, unread: automation.unread,
                                   attention: automation.attention, selected: automation.selected, expanded: expanded, toggle: toggle)
                .equatable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(automation.accessibilityLabel)
        .accessibilityValue(expanded.map { $0 ? "runs shown" : "runs hidden" } ?? "")
        .accessibilityAddTraits(automation.selected ? .isSelected : [])
        .accessibilityAction(named: expanded == true ? "Hide runs" : "Show runs") { if expanded != nil { toggle() } }
        .contextMenu { AutomationKeyMenu(key: key) }
    }

    private func forgePin(_ pin: SidebarForgePin) -> some View {
        let store = ForgeStore.of(hosts)
        let host = forgeHosts[pin.ref]
        return Button {
            if let host { ForgeHooks.open(ForgeItemKey(host: host, ref: pin.ref), store: store, navigator: navigator) }
        } label: {
            SHSidebarRow(pin.title, leading: .glyph(ForgeSymbol.kind(pin.ref.kind), attention: pin.tagTone == .attention),
                         accessory: .text(pin.tag, tone: pin.tagTone?.state))
                .equatable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pin.title), \(pin.place), \(pin.tag)")
        .contextMenu {
            if let host {
                Button("Unpin", systemImage: SHGlyph.pin.symbolName) {
                    Task { await store.setPinned(ForgeItemKey(host: host, ref: pin.ref), title: pin.title, pinned: false) }
                }
            }
        }
    }

    /// A thread opens its screen; a design its canvas.
    private func open(_ row: SidebarListRow) {
        if row.section == .designs, let design = PadSidebarRowMenu.design(row.id, hosts: hosts) {
            PadDesignHooks.open(design, navigator: navigator)
            return
        }
        switch row.id {
        case .remote(let ref): navigator.open(.thread(AgentRef(host: ref.hostID, agent: ref.agentID)))
        case .remoteDesign(let ref): PadDesignHooks.open(PadDesignRef(host: ref.hostID, design: ref.designID), navigator: navigator)
        case .local, .design, .dispatch: break
        }
    }
}

private extension SidebarActivityItem {
    var isDoneHeader: Bool {
        if case .header(.done, _, _) = self { true } else { false }
    }
}

/// A sender's chevron as a named VoiceOver action: the row is one element, so its button isn't reachable on its own.
private struct SentFoldAction: ViewModifier {
    let fold: SidebarFold?
    @Environment(MobileHosts.self) private var hosts

    func body(content: Content) -> some View {
        if let fold {
            content.accessibilityAction(named: fold.open ? "Hide threads it started" : "Show threads it started") {
                SidebarThreads.of(hosts).toggleFold(fold.key)
            }
        } else {
            content
        }
    }
}

/// A row's long press: a thread's is the Mac's row menu, a design's opens it in a new window.
private struct PadSidebarRowMenu: View {
    let row: SidebarListRow
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        if row.section == .designs {
            if let design = Self.design(row.id, hosts: hosts) { PadDesignWindowButton(design: design) }
        } else if case .remote(let ref) = row.id {
            ThreadRowMenu(thread: AgentRef(host: ref.hostID, agent: ref.agentID))
        }
    }

    /// The design a Designs row draws: its agent's design, or the design itself where its agent is gone.
    static func design(_ id: SidebarRowID, hosts: MobileHosts) -> PadDesignRef? {
        switch id {
        case .remote(let ref):
            hosts.host(ref.hostID)?.agent(ref.agentID)?.designID.map { PadDesignRef(host: ref.hostID, design: $0) }
        case .remoteDesign(let ref): PadDesignRef(host: ref.hostID, design: ref.designID)
        case .local, .design, .dispatch: nil
        }
    }
}

/// A pinned pull request or issue, as the Mac's Pinned draws it, with the host each is on.
extension ForgeStore {
    var sidebarPins: (pins: [SidebarForgePin], hosts: [ForgeItemRef: UUID]) {
        var lookup: [ForgeItemRef: UUID] = [:]
        let items = sidebars.flatMap { host, sidebar in sidebar.pins.map { (host: host, item: $0) } }
            .sorted { $0.item.pin.pinnedAt > $1.item.pin.pinnedAt }
        let pins = items.map { entry in
            lookup[entry.item.pin.ref] = lookup[entry.item.pin.ref] ?? entry.host
            return SidebarForgePin(entry.item, viewer: viewers[entry.host])
        }
        return (pins, lookup)
    }
}

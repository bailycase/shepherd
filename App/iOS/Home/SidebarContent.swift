import SwiftUI
import ShepherdUI
import ShepherdRemote
import ShepherdProtocol
import ShepherdSidebar

/// The Mac sidebar's destinations and lists, drawn once for every touch layout: the iPad's and the iPhone Duo's inner-display card
/// (`PadSidebar`) and the iPhone's Home (`HomeScreen`, which has no card). The same components (`SHSidebarDestination`, `SHSidebarSectionHeader`,
/// `SHSidebarRow`) draw the same rows (`SidebarDerivation.lists`, `SidebarLists.items`): New thread, Designs, Automations and Issues & PRs,
/// then Designs, Projects, Automations, Needs you, Working, Done, Pinned and Recents with the threads a thread sent under it.
/// `phone` adds what only the iPhone's list has: the Review queue row, and Needs you's way to its screen.
struct SidebarContent: View {
    var phone = false
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileProjects.self) private var projects

    var body: some View {
        let sidebar = SidebarThreads.of(hosts)
        let designs = PadDesigns.of(hosts)
        let automations = AutomationsStore.of(hosts)
        let forgeShown = ForgeEntry.available(hosts)
        let forge = ForgeStore.of(hosts)
        // The iPhone's list sits under the screens pushed over it, so it marks nothing.
        let pad = navigator.layout == .pad
        let pushed = pad ? navigator.padPath.last : nil
        let pins = forgeShown ? forge.sidebarPins : (pins: [], hosts: [:])
        let listing = sidebar.listing(.init(
            selected: pad ? navigator.selectedThread.map { .remote(RemoteAgentRef(hostID: $0.host, agentID: $0.agent)) } : nil,
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
        // The chord shows while a hardware keyboard is attached, as the Mac's does.
        let destinations = SidebarDerivation.destinations(
            shown: shown, newThreadChord: HardwareKeyboard.shared.attached ? MobileShortcut.newThread.display : "", designs: designs.available,
            automations: automations.unreadRuns.isEmpty ? .none : .count(automations.unreadRuns.count),
            forge: forgeShown ? forge.needsYou : 0)
        let review = phone ? HomeFeed.of(hosts).supervisionQueues.review.count : 0
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: SHSidebarMetrics.rowSpacing) {
                ForEach(destinations) { row in
                    SHSidebarDestination(row.title, icon: row.icon, selected: row.selected, child: row.child, trailing: row.trailing) {
                        open(row)
                    }
                    .equatable()
                    .accessibilityLabel(SidebarDerivation.accessibilityLabel(row))
                }
                if review > 0 {
                    SHSidebarDestination("Review queue", icon: .symbol(SHGlyph.reviewQueue.symbolName), trailing: .count(review)) {
                        navigator.openReviewQueue(hosts: hosts)
                    }
                    .equatable()
                    .accessibilityLabel("Review queue, \(review) to review")
                }
            }
            .padding(.vertical, SHSidebarMetrics.destinationsPadding)
            .padding(.horizontal, SHSidebarMetrics.listInset)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(listing.items) { item in
                    SidebarItem(item: item, forgeHosts: pins.hosts, done: listing.done, phone: phone)
                        .equatable()
                }
            }
            .padding(.horizontal, SHSidebarMetrics.listInset)
            .padding(.bottom, SH.Space.m)
        }
        // Automations' unread dots and paused triggers, read while their rows show.
        .task(id: listing.items.contains { if case .automation = $0 { true } else { false } }) { await automations.watch() }
        .task(id: forge.sessionsKey) { if forgeShown { await forge.loadRepos() } }
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

/// The sidebar's footer, the same on every layout: the Fleet line (it opens Fleet) and Settings.
struct SidebarFooterBar: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let settings = SettingsStore.of(hosts)
        let fleetRows = settings.fleetRows
        SHSidebarFooter(name: "", detail: fleetRows.isEmpty ? "" : "Fleet · \(FleetDeviceList.footer(fleetRows).detail)",
                        openDetail: { navigator.open(.settings(.fleet)) },
                        settings: { navigator.open(.settings(.root)) })
            .equatable()
            // The Fleet line's "1 asleep", read every so often while a Mac serves the fleet (the Fleet screen reads faster).
            .task(id: settings.showsFleet) {
                guard settings.showsFleet else { return }
                while !Task.isCancelled {
                    await settings.fleet.refresh(settings.hosts)
                    try? await Task.sleep(for: .seconds(MobileLayout.fleetFooterPoll))
                }
            }
    }
}

import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar

/// The sidebar's rows on this device: the Mac's own derivation (`SidebarDerivation.lists`, `SidebarLists.items`) run over each paired
/// Mac's pushed state, with this device's pins, completions and what was seen (`FleetSidebarState`) as the Mac's view model keeps them.
extension SidebarThreads {
    /// What the rows draw besides the threads.
    struct Inputs: Equatable {
        var selected: SidebarRowID?
        var designs: Bool
        var projects: [SidebarLogicalProject]
        var selectedAutomation: AutomationKey?
        var forgePins: [SidebarForgePin]
        var forgePinsProblem: String?
        var unreadRuns: Set<FleetRef>
        var unreadRunCounts: [AutomationKey: Int]
        var triggerStatuses: [AutomationKey: AutomationTriggerStatus]
    }

    struct Listing: Equatable {
        var items: [SidebarActivityItem]
        /// Done's rows, for Mark all seen.
        var done: [SidebarListRow]
    }

    private struct Cache {
        var source: SidebarSource
        var state: FleetSidebarState
        var inputs: Inputs
        var collapsed: Set<String>
        var folds: Set<String>
        var listing: Listing
    }

    /// Derived again only when an input changed (as `groups`), never per redraw.
    func listing(_ inputs: Inputs) -> Listing {
        let hostInputs = hosts.hosts.map { host in
            SidebarSource.Host(id: host.id, name: host.name,
                               state: SidebarSource.presentationState(host.threadState, children: [:]),
                               offline: !host.phase.isConnected, fleetID: host.fleetID)
        }
        let source = SidebarPaired.source(hosts: hostInputs, state: state, designs: inputs.designs,
                                          triggerStatuses: inputs.triggerStatuses, unreadRunCounts: inputs.unreadRunCounts,
                                          unreadRuns: Set(inputs.unreadRuns.map(\.agent)))
        if let cached = listingCache as? Cache, cached.source == source, cached.state == state, cached.inputs == inputs,
           cached.collapsed == collapsedSections, cached.folds == openFolds {
            return cached.listing
        }
        let lists = SidebarDerivation.lists(source, pins: SidebarPaired.pins(state), seen: SidebarPaired.seen(state))
        let collapsed = Set(collapsedSections.compactMap(SidebarActivitySection.init(rawValue:)))
        let presented = lists.presented(selected: inputs.selected, shortcuts: false, collapsed: collapsed, openFolds: openFolds)
        let items = presented.items(collapsed: collapsed, openRunGroups: openFolds, projects: inputs.projects,
                                    showsProjects: !inputs.projects.isEmpty, selectedAutomation: inputs.selectedAutomation,
                                    forgePins: inputs.forgePins, forgePinsProblem: inputs.forgePinsProblem)
        let listing = Listing(items: items, done: presented.done)
        listingCache = Cache(source: source, state: state, inputs: inputs, collapsed: collapsedSections, folds: openFolds, listing: listing)
        // Selecting a sender, or a thread it sent, shows what it sent; selecting a run opens its automation (as the Mac does).
        foldsHoldingSelection = { ref in
            let id = SidebarRowID.remote(RemoteAgentRef(hostID: ref.host, agentID: ref.agent))
            var keys: [String] = []
            for row in lists.all where row.id == id {
                keys += [row.fold?.key, row.sentRoot.map(SidebarSent.foldKey)].compactMap { $0 }
            }
            if let automation = lists.automations.first(where: { $0.id == id })?.foldedUnder {
                keys.append(SidebarLists.runGroupKey(automation))
            }
            return keys
        }
        return listing
    }

    func toggle(_ section: SidebarActivitySection) { toggleSection(section.rawValue) }

    /// Mark all seen on Done's header.
    func markSeen(_ rows: [SidebarListRow]) {
        markSeen(refs: rows.compactMap { row in
            guard case .remote(let ref) = row.id else { return nil }
            return FleetRef(host: ref.hostID, agent: ref.agentID)
        })
    }
}

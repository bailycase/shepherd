import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The sidebar's inputs on the iPhone and iPad, which have no thread host of their own: every Mac they are paired with is a
// connected (or offline) `SidebarSource.Host`, and the pins, completions and what was seen are `FleetSidebarState`'s, as the Mac
// keeps them in its own view model. The same `SidebarDerivation.lists` then groups them.

public enum SidebarPaired {
    /// A source whose threads are all on `hosts`.
    public static func source(hosts: [SidebarSource.Host], state: FleetSidebarState, designs: Bool = false,
                              triggerStatuses: [AutomationKey: AutomationTriggerStatus] = [:],
                              unreadRunCounts: [AutomationKey: Int] = [:], unreadRuns: Set<AgentID> = [],
                              hostRuns: [AutomationKey: AutomationRun] = [:]) -> SidebarSource {
        var source = SidebarSource(local: ShepherdState(), completions: completions(state), triggerStatuses: triggerStatuses,
                                   unreadRunCounts: unreadRunCounts, hostRuns: hostRuns, hosts: hosts, designs: designs)
        source.unreadRuns = unreadRuns
        return source
    }

    public static func pins(_ state: FleetSidebarState) -> SidebarPins {
        SidebarPins(state.pins.map { .remote(RemoteAgentRef(hostID: $0.host, agentID: $0.agent)) })
    }

    /// Each thread's completion as `FleetSidebarState` observed it.
    public static func completions(_ state: FleetSidebarState) -> [SidebarRowID: SidebarCompletions.Record] {
        Dictionary(uniqueKeysWithValues: state.completionStamps.map { ref, stamp in
            (SidebarRowID.remote(RemoteAgentRef(hostID: ref.host, agentID: ref.agent)),
             SidebarCompletions.Record(finished: stamp.finished, activity: nil, generation: stamp.generation, completedAt: stamp.completedAt))
        })
    }

    /// The completions whose Done row was seen.
    public static func seen(_ state: FleetSidebarState) -> [SidebarRowID: Int] {
        Dictionary(uniqueKeysWithValues: state.seenGenerations.map { ref, generation in
            (SidebarRowID.remote(RemoteAgentRef(hostID: ref.host, agentID: ref.agent)), generation)
        })
    }
}

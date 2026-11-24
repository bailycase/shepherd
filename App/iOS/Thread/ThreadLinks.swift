import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdRemote

/// Keeps a thread's links (ThreadLinkA) resolving against the threads of the host the thread belongs to: derived once per change
/// of that host's agents, never in the transcript's body. A chip or the peek's Open thread opens the linked thread.
struct ThreadLinksSync: View {
    let host: UUID
    let links: SHThreadLinks
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let found = hosts.host(host).map {
            ThreadLinkTable.links([ThreadLinkTable.Host(state: $0.state, tag: nil, location: $0.name)])
        } ?? []
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: found, initial: true) {
                links.open = { [navigator, host] id in navigator.open(.thread(AgentRef(host: host, agent: AgentID(rawValue: id)))) }
                links.update(found)
            }
    }
}

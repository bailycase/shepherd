import SwiftUI
import ShepherdCore
import ShepherdRemote
import ShepherdUI

// Thread links (ThreadLinkA): the threads a link in any conversation on this Mac resolves against, and what opening one does.

extension ShepherdViewModel {
    /// What the table is derived from: this Mac's agents, then each paired Mac's, tagged with its name.
    var threadLinkHosts: [ThreadLinkTable.Host] {
        [ThreadLinkTable.Host(state: state, tag: nil, location: ThreadLinkTable.thisMac, statusSince: statusSince)]
            + remoteHosts.connections.map { ThreadLinkTable.Host(state: $0.state, tag: $0.config.name, location: $0.config.name) }
    }

    /// A thread chip pressed, or its peek's Open thread: the thread opens, here or on the Mac it runs on.
    func openThreadLink(_ id: String) {
        let agent = AgentID(rawValue: id)
        if state.agents.contains(where: { $0.id == agent }) {
            selectAgent(agent)
        } else if let host = remoteHosts.connections.first(where: { $0.state.agents.contains { $0.id == agent } }) {
            selectRemoteAgent(hostID: host.id, agentID: agent)
        }
    }
}

extension EnvironmentValues {
    /// The agent whose thread this is: its composer's # picker never offers to link it.
    @Entry var threadLinkSelf: String? = nil
}

/// Keeps `ShepherdViewModel.threadLinks` current: derived once per change of the hosts' agents, never in a thread's body.
struct ThreadLinksSync: View {
    var vm: ShepherdViewModel

    var body: some View {
        let links = ThreadLinkTable.links(vm.threadLinkHosts)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: links, initial: true) { vm.threadLinks.update(links) }
    }
}

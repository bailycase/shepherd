import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Commit from review (MobileCommit, iPadCommit boards): the review's screens reach it through
/// these hooks. A host that commits from review (`reviewCommitCapability`) gets Commit…; an older
/// one keeps Commit as a turn the agent is asked to do.
@MainActor
enum CommitHooks {
    /// Whether `host` commits from review.
    static func available(host: MobileHost?) -> Bool {
        host?.supports(RemoteProtocol.reviewCommitCapability) == true
    }

    /// Opens the commit: a sheet on iPhone, the popover beside Commit… on iPad.
    static func open(thread: AgentRef, navigator: MobileNavigator, sizeClass: UserInterfaceSizeClass?) {
        if sizeClass == .regular {
            CommitStores.shared.popover = thread
        } else {
            navigator.present(.review(.commit(thread)))
        }
    }
}

/// One commit store per agent, kept while the app runs, so a commit that is still running shows
/// its progress when Commit… is opened again. `popover` is the thread whose iPad popover is open.
@MainActor
@Observable
final class CommitStores {
    static let shared = CommitStores()

    var popover: AgentRef?
    @ObservationIgnored private var stores: [AgentRef: ReviewCommitStore] = [:]

    /// The agent's store, asking its host through the connection current at each request.
    func store(for ref: AgentRef, hosts: MobileHosts) -> ReviewCommitStore {
        let store = stores[ref] ?? ReviewCommitStore()
        stores[ref] = store
        store.query = { [weak hosts] query in
            guard let client = hosts?.host(ref.host)?.connectedClient else {
                throw RemoteHostClientError.rejected(code: "not_sent", message: "The host is offline.")
            }
            return try await client.agentQuery(agentID: ref.agent, query: query)
        }
        return store
    }
}

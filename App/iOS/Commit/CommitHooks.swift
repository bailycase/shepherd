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
            navigator.commitPopover = thread
        } else {
            navigator.present(.review(.commit(thread)))
        }
    }
}

/// One commit store per agent, kept while the app runs, so a commit that is still running shows
/// its progress when Commit… is opened again. The navigator owns each window's popover.
@MainActor
@Observable
final class CommitStores {
    static let shared = CommitStores()

    @ObservationIgnored private var stores: [AgentRef: ReviewCommitStore] = [:]
    @ObservationIgnored private var forgottenHosts: Set<UUID> = []

    func forget(host: UUID) {
        forgottenHosts.insert(host)
        for (ref, store) in stores where ref.host == host { store.query = nil; store.reset() }
        stores = stores.filter { $0.key.host != host }
    }

    /// The agent's store, asking its host through the connection current at each request.
    func store(for ref: AgentRef, hosts: MobileHosts) -> ReviewCommitStore {
        if forgottenHosts.contains(ref.host) { return ReviewCommitStore() }
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

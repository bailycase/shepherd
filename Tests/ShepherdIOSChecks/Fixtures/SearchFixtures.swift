import Foundation
import ShepherdCore
import ShepherdProtocol

// Search track's screens: search (iPhone), the ⌘K palette (iPad), and the agent actions' sheets.
extension FixtureCatalog {
    static var search: [FixtureScreen] {
        let preview = FixtureData.ref(FixtureData.preview)
        return [
            FixtureScreen(name: "search", hosts: SearchFixtures.hosts(), routes: [.search(.search(query: "review"))]),
            FixtureScreen(name: "search-idle", hosts: SearchFixtures.hosts(), routes: [.search(.search(query: ""))]),
            FixtureScreen(name: "search-none", hosts: SearchFixtures.hosts(), routes: [.search(.search(query: "zebra"))]),
            FixtureScreen(name: "palette", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.palette(query: "review"))),
            FixtureScreen(name: "palette-actions", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.palette(query: ""))),
            FixtureScreen(name: "rename", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.rename(preview))),
            FixtureScreen(name: "delete", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.delete(FixtureData.ref(FixtureData.extensions)))),
            FixtureScreen(name: "delete-worktree", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.delete(FixtureData.ref(SearchFixtures.worktree)))),
        ]
    }
}

enum SearchFixtures {
    static let worktree = AgentID(rawValue: "agent-worktree")

    /// The shared hosts, with a worktree agent on Studio and every host answering conversation
    /// search (the host lowercases what it matched, as a Mac does) and the worktree's details.
    static func hosts() -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        hosts[0].state.agents.append(Agent(id: worktree, name: "Queue steering polish", spaceID: FixtureData.shepherdSpace.id,
                                           tabID: TabID(rawValue: "tab-worktree"), status: .done, nameIsFinal: true,
                                           worktreeBranch: "worktree/calm-stone-3831", worktreeBase: "origin/nightly",
                                           worktreePath: "/Users/dev/Shepherd/.worktrees/calm-stone-3831"))
        hosts[0].threads[worktree] = FixtureData.thread()
        hosts[0].reply = { request in
            answer(request, snippets: [
                FixtureData.preview: "open the review pane beside the thread once the preview settles, then",
                FixtureData.extensions: "the review extension reads the diff before it asks you",
            ])
        }
        hosts[1].reply = { request in
            answer(request, snippets: [FixtureData.buffer: "a review of the buffer flush found two copies of each"])
        }
        return hosts
    }

    private static func answer(_ request: RemoteRequest, snippets: [AgentID: String]) -> RemoteReply? {
        guard case .agentQuery(let id, let agent, let query) = request else { return nil }
        switch query {
        case .search(let text):
            let needle = text.lowercased()
            let snippet = snippets[agent].flatMap { $0.contains(needle) ? "…" + $0 + "…" : nil }
            return .agentResult(id: id, result: .search(snippet: snippet))
        case .worktreeInfo where agent == worktree:
            return .agentResult(id: id, result: .worktreeInfo(RemoteWorktreeInfo(
                path: "/Users/dev/Shepherd/.worktrees/calm-stone-3831", branch: "worktree/calm-stone-3831",
                warning: "2 uncommitted files and 1 unpushed commit",
                defaults: RemoteFinalizeOptions(base: "nightly", title: "Queue steering polish", body: "", autoCommit: true,
                                                deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash"),
                fingerprint: "fixture")))
        default:
            return nil
        }
    }
}

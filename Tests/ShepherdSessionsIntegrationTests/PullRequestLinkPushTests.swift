import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The sidebar's pull request badges come from the host (`servePullRequestLinks`): this Mac's app
/// is pushed each thread's link as it changes and as it connects, asks the host to look one up
/// again (the side pane's Pull request tab), and a turn's end looks it up again on the host.
@Suite("Pull request links pushed to this Mac's app", .mainActorExclusive)
@MainActor
struct PullRequestLinkPushTests {
    @Test func theHostsLinksReachThisMacsAppAsTheyChange() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        let pane = LeafPane(cwd: h.dir.path, agentID: AgentID())
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let id = try #require(pane.agentID)
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab],
                                                  agents: [Agent(id: id, name: "refunds", spaceID: space.id, tabID: tab.id, paneID: pane.id)]))
        let ref = ForgeItemRef(kind: .pullRequest, repo: "acme/web", number: 31)
        let lookups = Locked<[String]>([])
        var found: PullRequestState? = .open
        h.server.servePullRequestLinks(PullRequestLinkHosting(closeOnMerge: { false }, lookup: { cwd in
            lookups.withValue { $0.append(cwd) }
            return found.map { ThreadPullRequest(ref: ref, state: $0) }
        }, removeWorktreeAgent: { _ in }))
        h.server.serveAgentQueries(WorktreeHosting(defaults: { .init(generateDescription: false) }, deleteAgent: { _, _ in }))
        let path = h.dir.appendingPathComponent("h.sock").path, tokenURL = h.dir.appendingPathComponent("remote-token")
        try h.server.startLocalListener(path: path, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        func connect(_ pushes: Locked<[[AgentID: ThreadPullRequest]]>) async throws -> RemoteHostClient {
            let app = RemoteHostClient(localSocket: path)
            app.onPullRequestLinks = { links, _ in pushes.withValue { $0.append(links) } }
            _ = try await app.connect(host: "", port: 0, token: token, clientName: "Shepherd",
                                      capabilities: RemoteProtocol.clientCapabilities + [RemoteProtocol.localThreadsCapability])
            return app
        }
        let pushes = Locked<[[AgentID: ThreadPullRequest]]>([])
        let app = try await connect(pushes)
        defer { app.disconnect() }
        #expect(app.capabilities.contains(RemoteProtocol.pullRequestLinkCapability))

        // The side pane asks; the host looks it up in the thread's folder and pushes the badge.
        guard case .pullRequest(let link) = try await app.agentQuery(agentID: id, query: .pullRequest) else {
            Issue.record("expected the thread's pull request"); return
        }
        #expect(link?.ref == ref && link?.state == .open)
        #expect(lookups.current == [h.dir.path])
        try await eventuallyOnMain("the link pushed") { pushes.current.last?[id]?.state == .open }

        // An app that connects later is told the links at once.
        let later = Locked<[[AgentID: ThreadPullRequest]]>([])
        let second = try await connect(later)
        defer { second.disconnect() }
        try await eventuallyOnMain("the links on connect") { later.current.first?[id]?.ref == ref }

        // A turn that ends looks it up again: merged now.
        found = .merged
        let reporter = try ExtensionClient(path: h.socketPath)
        defer { reporter.closeConnection() }
        try reporter.send(.setAgentStatus(agentID: id, status: .working))
        try await eventuallyOnMain("the turn to start") { h.server.state.agents.first?.status == .working }
        try reporter.send(.setAgentStatus(agentID: id, status: .done))
        try await eventuallyOnMain("the merge pushed after the turn") { pushes.current.last?[id]?.state == .merged }
        #expect(lookups.current.count == 2)
    }
}

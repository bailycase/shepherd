import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A space's apps over the listener (`apps.v1`): a client lists a host's space apps and its This
/// Mac apps, runs one in a thread's folder, sees it running, stops it, and is refused an app or a
/// space the host doesn't have. Every file lives in the scratch host's folder.
@Suite("Remote apps", .integrationTimeLimit)
struct RemoteAppsTests {
    static func refusal(_ body: () async throws -> RemoteAppsResult) async -> String? {
        do { _ = try await body(); return nil } catch RemoteHostClientError.rejected(let code, _) { return code } catch { return "\(error)" }
    }

    @Test func aClientListsRunsAndStopsASpacesApps() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let dir = host.host.dir
        let home = dir.appendingPathComponent("home").path
        let root = dir.appendingPathComponent("acme-web").path
        let worktree = dir.appendingPathComponent("acme-web-refunds").path
        for folder in [home, root, worktree] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try AppsFile.save([AppDefinition(name: "Web app", command: "pwd; echo 'ready on http://localhost:4321'; sleep 30",
                                         quickAction: true)], to: AppsFile.url(in: root))
        try AppsFile.save([AppDefinition(name: "Docs", command: "true")], to: AppsFile.url(in: home))
        host.server.hooks = HookCatalog(home: home, support: dir.appendingPathComponent("support"))
        host.server.apps.setLauncher(["/bin/sh", "-c"])
        let space = Space(name: "acme-web", path: root)
        try await host.server.addSpace(space)
        // A worktree thread: its app runs in its own checkout.
        let pane = LeafPane(cwd: worktree)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "Add refund events", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await host.server.addAgent(agent, withTab: tab)

        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.appsCapability))

        let listed = try await client.apps(.list(spaceID: space.id))
        #expect(listed.space == "acme-web")
        #expect(listed.apps.map(\.app.name) == ["Web app", "Docs"])
        #expect(listed.apps.map(\.mac) == [false, true])
        #expect(listed.apps.allSatisfy { $0.run == nil })

        let started = try await client.apps(.run(spaceID: space.id, name: "Web app", mac: false, agentID: agent.id))
        #expect(started.apps.first?.run?.isLive == true)
        let key = AppKey(scope: .space(space.id), name: "Web app")
        try await eventually("the app to print its folder and port") {
            let printed = await host.server.apps.lines(key, tail: 5)
            let run = try await client.apps(.list(spaceID: space.id)).apps.first?.run
            return printed.contains(PiHome.canonical(worktree)) && run == RemoteAppRun(status: .running, port: 4321)
        }

        _ = try await client.apps(.stop(spaceID: space.id, name: "Web app", mac: false))
        try await eventually("the app to stop") {
            guard case .exited? = (try await client.apps(.list(spaceID: space.id))).apps.first?.run?.status else { return false }
            return true
        }

        #expect(await Self.refusal { try await client.apps(.run(spaceID: space.id, name: "Nope", mac: false, agentID: nil)) } == "no_such_app")
        #expect(await Self.refusal { try await client.apps(.list(spaceID: SpaceID())) } == "no_such_space")
    }
}

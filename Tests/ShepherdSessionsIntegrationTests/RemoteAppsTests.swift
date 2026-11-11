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
            return printed.contains(PiHome.canonical(worktree)) && run?.status == .running && run?.port == 4321
        }

        _ = try await client.apps(.stop(spaceID: space.id, name: "Web app", mac: false))
        try await eventually("the app to stop") {
            guard case .exited? = (try await client.apps(.list(spaceID: space.id))).apps.first?.run?.status else { return false }
            return true
        }

        #expect(await Self.refusal { try await client.apps(.run(spaceID: space.id, name: "Nope", mac: false, agentID: nil)) } == "no_such_app")
        #expect(await Self.refusal { try await client.apps(.list(spaceID: SpaceID())) } == "no_such_space")
    }

    /// This Mac's app over `host.sock` (`apps.v2`): it runs a This Mac app with no space, reads its
    /// output, restarts it after it ends, and follows every run through `appsChanged` pushes (one
    /// on connect, then one per change) with no polling.
    @Test func thisMacsAppRunsItsAppsOnTheHostAndFollowsTheirRuns() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let dir = host.host.dir
        let home = dir.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try AppsFile.save([AppDefinition(name: "Postgres", command: "echo pg-up; sleep 30")], to: AppsFile.url(in: home))
        host.server.hooks = HookCatalog(home: home, support: dir.appendingPathComponent("support"))
        host.server.apps.setLauncher(["/bin/sh", "-c"])
        let socket = dir.appendingPathComponent("h.sock").path, tokenURL = dir.appendingPathComponent("local-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)

        let app = RemoteHostClient(localSocket: socket)
        let pushes = Locked<[[RemoteAppProcess]]>([])
        app.onAppsChanged = { processes in pushes.withValue { $0.append(processes) } }
        _ = try await app.connect(host: "", port: 0, token: try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                                  clientName: "Shepherd", capabilities: RemoteProtocol.clientCapabilities + [RemoteProtocol.localThreadsCapability])
        defer { app.disconnect() }
        #expect(app.capabilities.contains(RemoteProtocol.appsV2Capability))
        try await eventually("the runs on connect") { pushes.current == [[]] }

        func postgres() -> RemoteAppRun? { pushes.current.last?.first { $0.spaceID == nil && $0.name == "Postgres" }?.run }
        let started = try await app.apps(.run(spaceID: nil, name: "Postgres", mac: true, agentID: nil))
        #expect(started.space == "" && started.apps.map(\.app.name) == ["Postgres"])
        try await eventually("the pushed run") { postgres()?.status == .running && postgres()?.command == "echo pg-up; sleep 30" }
        #expect(postgres()?.directory == home)
        try await eventually("its output") { try await app.apps(.output(spaceID: nil, name: "Postgres", tail: 5)).lines == ["pg-up"] }
        #expect(try await app.apps(.processes).processes?.map(\.name) == ["Postgres"])

        _ = try await app.apps(.stop(spaceID: nil, name: "Postgres", mac: true))
        try await eventually("the pushed exit") { if case .exited? = postgres()?.status { true } else { false } }
        _ = try await app.apps(.restart(spaceID: nil, name: "Postgres"))
        try await eventually("the pushed restart") { postgres()?.isLive == true }
        _ = try await app.apps(.stop(spaceID: nil, name: "Postgres", mac: true))
        try await eventually("the second exit") { postgres()?.isLive == false }

        #expect(await Self.refusal { try await app.apps(.run(spaceID: nil, name: "Nope", mac: true, agentID: nil)) } == "no_such_app")
        #expect(await Self.refusal { try await app.apps(.output(spaceID: SpaceID(), name: "Postgres", tail: 5)) } == "no_such_space")
    }
}

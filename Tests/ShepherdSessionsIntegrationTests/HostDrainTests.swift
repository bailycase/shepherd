import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The background host's handoff to another build: it drains (keeps serving, exits once no agent
/// is busy, or at the cap) when its bundle changes on disk or a newer app asks over `host.sock`.
@Suite("Host drain", .integrationTimeLimit)
struct HostDrainTests {
    /// A host serving one thread in `status`.
    static func host(_ status: AgentStatus) async throws -> (ScratchServer, ShepherdState) {
        let h = try ScratchServer.fresh()
        let space = Fixture.space("acme-web")
        let state = Fixture.workspace([Fixture.agent(in: space, name: "Fix the checkout", status: status)], space: space)
        try await h.seed(state)
        return (h, state)
    }

    @Test(arguments: [AgentStatus.working, .blocked])
    func aBusyAgentKeepsADrainingHostUpUntilItSettles(_ status: AgentStatus) async throws {
        let (h, state) = try await Self.host(status)
        defer { h.stop() }
        let exited = Locked(false)
        let drain = await HostDrain(server: h.server, poll: .milliseconds(10)) { exited.withValue { $0 = true } }
        await drain.begin("test")
        #expect(await !h.server.quietForDrain)
        #expect(!exited.current, "the host keeps serving while its agent is \(status)")

        var settled = state
        settled.agents[0].status = .done
        try await h.seed(settled)
        try await eventually("the drained host to exit") { exited.current }
    }

    @Test func aDrainExitsAtItsCapWithAnAgentStillWorking() async throws {
        let (h, _) = try await Self.host(.working)
        defer { h.stop() }
        let exited = Locked(false)
        let drain = await HostDrain(server: h.server, cap: .zero, poll: .milliseconds(10)) { exited.withValue { $0 = true } }
        await drain.begin("test")
        try await eventually("the capped drain to exit") { exited.current }
    }

    @Test func onlyTheLocalAppMayAskTheHostToDrain() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let asked = Locked(0)
        h.server.onDrainRequest = { asked.withValue { $0 += 1 } }
        let tokenURL = h.dir.appendingPathComponent("remote-token")
        let path = h.dir.appendingPathComponent("h.sock").path
        try h.server.startLocalListener(path: path, tokenURL: tokenURL)
        let port = try h.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        let app = RemoteHostClient(localSocket: path)
        _ = try await app.connect(host: "", port: 0, token: token, clientName: "Shepherd")
        defer { app.disconnect() }
        #expect(app.capabilities.contains(RemoteProtocol.hostDrainCapability))
        try await app.drain()
        try await eventually("the host to be asked to drain") { asked.current == 1 }

        let phone = RemoteHostClient()
        _ = try await phone.connect(host: "127.0.0.1", port: port, token: token, clientName: "iPhone")
        defer { phone.disconnect() }
        #expect(!phone.capabilities.contains(RemoteProtocol.hostDrainCapability))
        await #expect(throws: RemoteHostClientError.self) { try await phone.drain() }
        #expect(asked.current == 1, "a paired device never drains the host")
    }

    @Test func theWatchSeesTheBundleReplacedOrRemoved() async throws {
        let dir = try makeScratchDirectory("bundle")
        defer { try? FileManager.default.removeItem(at: dir) }
        func bundle(_ name: String, version: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleVersion": version] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let app = try bundle("Acme.app", version: "100")
        #expect(BundleVersionWatch.version(of: app) == "100")

        // Sparkle's way: the new bundle is moved over the old one.
        let seen = Locked<[String?]>([])
        let watch = BundleVersionWatch(bundle: app, running: "100", every: .seconds(3600)) { version in
            seen.withValue { $0.append(version) }
        }
        defer { watch.cancel() }
        let update = try bundle("Update.app", version: "101")
        _ = try FileManager.default.replaceItemAt(app, withItemAt: update)
        try await eventually("the watch to see the new build") { seen.current == ["101"] }

        // Moved to the Trash: the bundle is gone.
        let gone = Locked<[String?]>([])
        let trashed = BundleVersionWatch(bundle: app, running: "101", every: .seconds(3600)) { version in
            gone.withValue { $0.append(version) }
        }
        defer { trashed.cancel() }
        try FileManager.default.moveItem(at: app, to: dir.appendingPathComponent("Trash.app"))
        try await eventually("the watch to see the bundle gone") { gone.current == [nil] }
    }
}

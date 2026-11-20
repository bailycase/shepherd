import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A paired device renames, hides, reorders and removes the spaces of its own host (`RemoteRequest.spaceLifecycle`), and nothing else:
/// not another host's space, not one the host keeps out of sight, and never from a Mac in the fleet.
@Suite("Space lifecycle from a device", .integrationTimeLimit)
struct SpaceLifecycleTests {
    /// Two spaces with folders that hold a file, a thread in the first, and the reserved space the host keeps for threads with no space.
    private struct Seeded {
        let web: Space, api: Space, reserved: Space
        let thread: (agent: Agent, tab: ShepherdCore.Tab)

        init(in host: ScratchServer) throws {
            func folder(_ name: String) throws -> Space {
                let url = host.dir.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("keep".utf8).write(to: url.appendingPathComponent("notes.txt"))
                return Space(name: name, path: url.path)
            }
            web = try folder("acme-web")
            api = try folder("acme-api")
            reserved = Space(name: "No space", path: host.dir.path, hidden: true, holdsThreads: true)
            thread = Fixture.agent(in: web)
        }

        var state: ShepherdState { ShepherdState(spaces: [web, api, reserved], tabs: [thread.tab], agents: [thread.agent]) }
    }

    private func shown(_ r: RemoteHost) -> [String] { r.server.state.spaces.filter { !$0.hidden }.map(\.name) }

    @Test func aDeviceRenamesHidesReordersAndRemovesItsHostsSpaces() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let seed = try Seeded(in: r.host)
        try await r.host.seed(seed.state)
        let client = try await r.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.spaceLifecycleCapability))

        try await client.spaceLifecycle(.rename(name: "  acme-site  "), spaceID: seed.web.id)
        #expect(shown(r) == ["acme-site", "acme-api"], "the name is trimmed, and the space keeps its place and its folder")
        #expect(r.server.state.spaces.first { $0.id == seed.web.id }?.path == seed.web.path)

        try await client.spaceLifecycle(.setSidebarHidden(hidden: true), spaceID: seed.web.id)
        #expect(r.server.state.spaces.first { $0.id == seed.web.id }?.sidebarHidden == true)
        try await client.spaceLifecycle(.setSidebarHidden(hidden: false), spaceID: seed.web.id)
        #expect(r.server.state.spaces.first { $0.id == seed.web.id }?.sidebarHidden == false)

        try await client.spaceLifecycle(.move(before: seed.web.id), spaceID: seed.api.id)
        #expect(shown(r) == ["acme-api", "acme-site"])
        try await client.spaceLifecycle(.move(before: nil), spaceID: seed.api.id)
        #expect(shown(r) == ["acme-site", "acme-api"])

        // Remove forgets the space and its threads in Shepherd's record. It never touches a folder.
        try await client.spaceLifecycle(.remove, spaceID: seed.web.id)
        #expect(shown(r) == ["acme-api"])
        #expect(r.server.state.agents.isEmpty && r.server.state.tabs.isEmpty)
        let kept = URL(fileURLWithPath: seed.web.path).appendingPathComponent("notes.txt")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "keep")
        #expect(r.server.state.spaces.contains { $0.id == seed.reserved.id }, "the reserved space is as it was")
    }

    @Test func aRenameThatNamesNothingIsRefusedAndChangesNothing() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let seed = try Seeded(in: r.host)
        try await r.host.seed(seed.state)
        let client = try await r.typed()
        defer { client.disconnect() }
        do {
            try await client.spaceLifecycle(.rename(name: "   "), spaceID: seed.web.id)
            Issue.record("An empty name was accepted")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "invalid_name")
        }
        #expect(r.server.state == seed.state)
    }

    /// An unknown space, another host's, and one the host keeps out of a device's sight (as a `move` target too) are refused alike.
    @Test func aDeviceCannotActOnASpaceItIsNotShown() async throws {
        let r = try RemoteHost(), other = try RemoteHost()
        defer { r.stop(); other.stop() }
        let seed = try Seeded(in: r.host)
        try await r.host.seed(seed.state)
        let theirs = Space(name: "acme-billing", path: other.host.dir.path)
        try await other.host.seed(ShepherdState(spaces: [theirs]))
        let client = try await r.raw(authenticated: false)
        try await client.hello(token: r.token, capabilities: RemoteProtocol.clientCapabilities)

        let actions: [(String, SpaceID, RemoteSpaceLifecycle)] = [
            ("unknown", SpaceID(), .remove),
            ("another host's", theirs.id, .remove),
            ("another host's rename", theirs.id, .rename(name: "mine now")),
            ("reserved", seed.reserved.id, .remove),
            ("reserved hide", seed.reserved.id, .setSidebarHidden(hidden: false)),
            ("move of the reserved", seed.reserved.id, .move(before: nil)),
            ("move before the reserved", seed.api.id, .move(before: seed.reserved.id)),
            ("move before an unknown", seed.api.id, .move(before: SpaceID())),
            ("move before another host's", seed.api.id, .move(before: theirs.id)),
        ]
        for (index, (label, spaceID, action)) in actions.enumerated() {
            let id = index + 1
            try client.send(.spaceLifecycle(id: id, spaceID: spaceID, action: action))
            guard case .error(id, "no_such_space", _) = try await client.next() else { Issue.record("\(label): expected no_such_space"); continue }
        }
        #expect(r.server.state == seed.state, "nothing changed")
        #expect(other.server.state.spaces == [theirs])
        try client.send(.stateFetch(id: 50))
        guard case .state(50, _) = try await client.next() else { Issue.record("the connection stopped serving"); return }
    }

    /// Hide changes `sidebarHidden` and nothing else: a rename or Locate Folder… the Mac makes while the request is in flight is never
    /// written back over. A relocation ticks on the host's queue throughout, so the request's hops to the queue interleave with it; a
    /// Hide that reads the space and then replaces it puts back a path the ticks have already moved on from.
    @Test func hideNeverRevertsAConcurrentChangeToTheSpace() async throws {
        final class Ticks: @unchecked Sendable {
            var count = 0, stopped = false, reverted: String?
        }
        let r = try RemoteHost()
        defer { r.stop() }
        let seed = try Seeded(in: r.host)
        try await r.host.seed(seed.state)
        let id = seed.web.id, server = r.server
        let ticks = Ticks()
        func tick() {
            guard !ticks.stopped else { return }
            guard let index = server.store.state.spaces.firstIndex(where: { $0.id == id }) else { return }
            let path = server.store.state.spaces[index].path
            if ticks.count > 0, path != "/moved/\(ticks.count)", ticks.reverted == nil { ticks.reverted = "\(path) after /moved/\(ticks.count)" }
            ticks.count += 1
            try? server.mutateState { $0.spaces[index].path = "/moved/\(ticks.count)" }
            server.queue.async { tick() }
        }
        server.queue.async { tick() }
        for round in 0..<20 {
            try await server.performSpaceLifecycle(.setSidebarHidden(hidden: round % 2 == 0), on: id)
        }
        await server.enqueueValue {
            ticks.stopped = true
            let path = server.store.state.spaces.first { $0.id == id }?.path
            if path != "/moved/\(ticks.count)", ticks.reverted == nil { ticks.reverted = "\(path ?? "none") after /moved/\(ticks.count)" }
        }
        #expect(ticks.reverted == nil, "a Hide put back an older path: \(ticks.reverted ?? "")")
        #expect(ticks.count > 20, "the Mac's changes ran alongside")
        let space = try #require(server.state.spaces.first { $0.id == id })
        #expect(space.sidebarHidden == false && space.name == seed.web.name)
    }

    @Test func aHostWithoutTheCapabilityRefusesBeforeAnything() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let seed = try Seeded(in: r.host)
        try await r.host.seed(seed.state)
        r.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.spaceLifecycleCapability }
        let client = try await r.raw()
        try client.send(.spaceLifecycle(id: 1, spaceID: seed.web.id, action: .remove))
        guard case .error(1, "unsupported", _) = try await client.next() else { Issue.record("expected unsupported"); return }
        #expect(r.server.state == seed.state)

        // The client does not send it at all.
        let typed = try await r.typed()
        defer { typed.disconnect() }
        do {
            try await typed.spaceLifecycle(.remove, spaceID: seed.web.id)
            Issue.record("An older host was sent the request")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "update_required")
        }
    }

    /// A Mac in the fleet holds a token of its own, and the Mac lets it do none of this: even for a space it shows.
    @Test func aMacInTheFleetCannotChangeSpaces() async throws {
        let a = try await FleetPairingTests.Mac("MacBook Pro"), b = try await FleetPairingTests.Mac("Mac mini")
        defer { a.stop(); b.stop() }
        let seed = try Seeded(in: a.host)
        try await a.host.seed(seed.state)
        try await b.pair(with: a, code: try await a.startJoin())
        try await a.waitForLink(to: b)

        let peerToken = try #require(try b.record(of: a.name)["myToken"] as? String)
        let peer = try RawRemote(port: a.port)
        try await peer.hello(token: peerToken)
        for (index, action) in [RemoteSpaceLifecycle.rename(name: "taken"), .setSidebarHidden(hidden: true), .move(before: nil), .remove].enumerated() {
            let id = index + 2
            try peer.send(.spaceLifecycle(id: id, spaceID: seed.web.id, action: action))
            guard case .error(id, "forbidden", _) = try await peer.next() else { Issue.record("\(action): expected forbidden"); continue }
        }
        #expect(a.server.state == seed.state, "nothing changed")

        // The same space, from a device of A's own, goes through.
        let device = try RawRemote(port: a.port)
        try await device.hello(token: a.clientToken, capabilities: RemoteProtocol.clientCapabilities)
        try device.send(.spaceLifecycle(id: 2, spaceID: seed.web.id, action: .setSidebarHidden(hidden: true)))
        // A device is also pushed the state: read to the answer.
        let frames = try await device.frames(until: { if case .ok(2) = $0 { true } else if case .error(2, _, _) = $0 { true } else { false } })
        #expect(frames.last == .ok(id: 2))
        #expect(a.server.state.spaces.first { $0.id == seed.web.id }?.sidebarHidden == true)
    }
}

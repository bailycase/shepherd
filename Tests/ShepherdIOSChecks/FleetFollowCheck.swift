import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A phone that keeps up with its fleet: App/iOS/Hosts/MobileHosts.swift connected over real TCP to fake Macs of one fleet, with tokens in
// memory and a scratch preferences domain. Each fake Mac answers `fleetRead` with the members it holds and pushes `fleetViewChanged`
// when they change, as a host does. Built and run by run.sh on macOS.
@main
struct FleetFollowCheck {
    static func member(_ mac: FakeMac, _ hosts: [String], name: String? = nil) -> FleetViewMember {
        FleetViewMember(hostID: mac.hostID, name: name ?? mac.name, port: mac.port, routes: hosts.map { FleetReportedRoute(host: $0, kind: .lan) })
    }

    /// What `mac` answers when its fleet holds `members`.
    static func view(of mac: FakeMac, _ members: [FleetViewMember]) -> FleetSnapshot {
        FleetSnapshot(enabled: true, hostID: mac.hostID, name: mac.name, members: members)
    }

    /// `mac` now says its fleet holds `members`, and tells the phones that follow it.
    static func tell(_ mac: FakeMac, _ members: [FleetViewMember]) {
        mac.view = view(of: mac, members)
        mac.pushViewChanged()
    }

    @MainActor
    static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-ios-follow-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func scratchDefaults(_ name: String) -> UserDefaults { UserDefaults(suiteName: scratch.appendingPathComponent(name).path)! }
        let pause: (Duration) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(20)) }

        let fleet = FakeFleet()
        let mini = try FakeMac(name: "Mac mini", fleet: fleet)
        let studio = try FakeMac(name: "Mac Studio", fleet: fleet, hostID: UUID())
        let office = try FakeMac(name: "Office Mac", fleet: fleet, hostID: UUID())
        defer { mini.stop(); studio.stop(); office.stop() }
        fleet.members = [mini]
        let local = ["127.0.0.1"]
        mini.view = view(of: mini, [member(mini, local)])
        studio.view = view(of: studio, [member(studio, local)])

        let defaults = scratchDefaults("phone"), tokens = HostTokens.memory()
        var probed: [String] = []
        let phone = MobileHosts(defaults: defaults, tokens: tokens, device: .init(name: "Ada's iPhone", kind: .iphone), pause: pause,
                                probe: { host, _ in probed.append(host); return host == "no-such-mac.invalid" ? studio.hostID : nil })
        var left: [UUID] = []
        phone.onFleetLeft = { left.append($0) }
        fleet.code = "482913"
        let ids = try await phone.pair(address: "127.0.0.1", port: mini.port, code: "482913")
        check(ids.count == 1 && phone.host(ids[0])?.fleetID == mini.hostID, "paired with the Mac mini, whose id it knows")
        // A Mac the user paired themselves, on the shared token: the fleet never touches it.
        let home = try phone.add(RemoteHostEntry(name: "Office Mac", address: "127.0.0.1", port: String(office.port), token: fleet.sharedToken))
        let identity = try phone.deviceIdentity()
        phone.setForeground(true)
        try await waitUntil("both connected") { phone.hosts.allSatisfy { $0.phase == .connected } }
        check(phone.hosts.count == 2, "nothing is added while the fleet is one Mac")
        // The Mac the user added is offered the device's own token, as any older pairing is, and still isn't in the fleet's group.
        try await waitUntil("the Office Mac given the device's own token") { fleet.enrollments == 1 && (try? tokens.read(home)) == identity.token }

        // The Mac Studio joins the fleet: the phone gets it, with the same token and without pairing again.
        let accepted = fleet.accepted
        let studioRoutes = ["no-such-mac.invalid", "127.0.0.1"]
        studio.view = view(of: studio, [member(studio, studioRoutes)])
        tell(mini, [member(mini, local), member(studio, studioRoutes)])
        try await waitUntil("the Mac Studio added and connected") { phone.hosts.first { $0.fleetID == studio.hostID }?.phase == .connected }
        let added = phone.hosts.first { $0.fleetID == studio.hostID }!
        try check(tokens.read(added.id) == identity.token, "it holds the device's own token")
        check(fleet.accepted == accepted && fleet.enrollments == 1, "no new pairing and no new offer")
        check(added.name == "Mac Studio" && added.record.routes.map(\.host) == ["no-such-mac.invalid", "127.0.0.1"]
              && added.record.routes.allSatisfy { $0.port == studio.port && $0.kind == .lan }, "its routes are the fleet's, in order")
        check(added.routeIndex == 1, "the first route that answers carries it: the second")
        check(Set(defaults.stringArray(forKey: MobileHosts.ownTokenKey) ?? []).contains(added.id.uuidString), "it is marked as on the device's own token")
        let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: MobileHosts.recordsKey)!) as! [[String: Any]]
        check(saved.count == 3 && saved.allSatisfy { $0["token"] == nil }, "saved, and no token in the records")

        // The network changed: a host on a later route asks about the earlier ones, and one on its first doesn't.
        let session = added.session
        phone.networkChanged()
        try await waitUntil("the earlier route asked about, and the connection renewed") { probed.contains("no-such-mac.invalid") && added.session != session && added.phase == .connected }
        check(!probed.contains("127.0.0.1"), "a host on its first route isn't asked about")

        // It is renamed and its routes change: the fleet's word is kept.
        tell(studio, [member(studio, local, name: "Build Studio")])
        tell(mini, [member(mini, local), member(studio, local, name: "Build Studio")])
        try await waitUntil("the rename") { added.name == "Build Studio" && added.record.routes.map(\.host) == ["127.0.0.1"] }
        check(phone.hosts.count == 3 && added.phase == .connected, "renamed in place, still connected")

        // Its address changes (a new port stands in for a new address): the fleet reports it and the phone follows it with the same token.
        studio.stop()
        try await waitUntil("the connection lost") { !added.phase.isConnected }
        let moved = try FakeMac(name: "Build Studio", fleet: fleet, hostID: studio.hostID)
        defer { moved.stop() }
        moved.view = view(of: moved, [member(moved, local)])
        tell(mini, [member(mini, local), member(moved, local)])
        try await waitUntil("reached at its new address") { added.phase == .connected && added.record.port == moved.port }
        check(fleet.accepted == accepted && phone.hosts.filter { $0.fleetID == studio.hostID }.count == 1, "the same record, matched by id, and no new pairing")

        // It leaves the fleet: the phone drops it and says so, and keeps the Mac it paired with and the one the user added.
        tell(mini, [member(mini, local)])
        try await waitUntil("the Mac Studio dropped") { phone.host(added.id) == nil }
        check(left == [added.id], "the app is told, to clear what it kept for it")
        check(Set(phone.hosts.map(\.id)) == Set(ids + [home]), "the others stay")
        try check(tokens.read(added.id) == nil, "its token is gone")

        // Back in the fleet it is added again; once the user forgets it, it stays forgotten.
        tell(mini, [member(mini, local), member(moved, local)])
        try await waitUntil("the Mac Studio back") { phone.hosts.contains { $0.fleetID == moved.hostID } }
        try phone.forget(phone.hosts.first { $0.fleetID == moved.hostID }!.id)
        tell(mini, [member(mini, local), member(moved, local)])
        try await Task.sleep(for: .milliseconds(300))
        check(!phone.hosts.contains { $0.fleetID == moved.hostID }, "a Mac the user forgot is not added again")

        // The device is revoked on another Mac: its token is refused, it shows that, and it reads nothing more.
        let reads = { fleet.heard.filter { $0.contains("\"fleetRead\"") }.count }
        let before = reads()
        fleet.refuse(token: identity.token)
        phone.retry(ids[0])
        try await waitUntil("the token refused") { phone.host(ids[0])?.phase.failure?.kind == .tokenRefused }
        tell(mini, [member(mini, local), member(moved, local)])
        try await Task.sleep(for: .milliseconds(300))
        check(reads() == before && phone.hosts.count == 2, "a revoked device reads and adds nothing")
        phone.setForeground(false)

        // A host from before the capability: its view is not read, so nothing is added and nothing is removed.
        let oldFleet = FakeFleet()
        oldFleet.follows = false
        let oldMac = try FakeMac(name: "Mac mini", fleet: oldFleet)
        defer { oldMac.stop() }
        oldFleet.members = [oldMac]
        oldMac.view = view(of: oldMac, [member(oldMac, local), member(studio, local)])
        let legacy = MobileHosts(defaults: scratchDefaults("legacy"), tokens: HostTokens.memory(), device: .phone, pause: pause)
        oldFleet.code = "654321"
        _ = try await legacy.pair(address: "127.0.0.1", port: oldMac.port, code: "654321")
        legacy.setForeground(true)
        try await waitUntil("the old Mac connected") { legacy.hosts.allSatisfy { $0.phase == .connected } }
        oldMac.pushViewChanged()
        try await Task.sleep(for: .milliseconds(300))
        check(legacy.hosts.count == 1 && !oldFleet.heard.contains { $0.contains("\"fleetRead\"") }, "a Mac without the capability is not read")
        legacy.setForeground(false)
        print("PASS: a phone follows its fleet: a Mac that joins is added with the same token, routed in order, renamed, found at a new address, dropped when it leaves, kept when the user paired it, not added again once forgotten, ignored from a host without the capability, and silent once revoked")
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ what: String) rethrows {
        guard try condition() else { fatalError("FAILED: \(what)") }
    }

    @MainActor
    static func waitUntil(_ what: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("timed out: \(what)")
    }
}

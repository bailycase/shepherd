import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// App/iOS/Hosts/MobileHosts.swift and MobilePairing.swift against fake Macs of a fleet over real TCP, with
// tokens in memory (never the Keychain) and a scratch preferences domain. Built and run by run.sh on macOS.
// The fake Macs answer what a host answers (`fleetIdentify`, `fleetPairDevice`, `fleetEnrollDevice`, `hello`
// with the shared token or a device token), so this is the device side of pairing: what it sends, what it
// stores and where, and that an older pairing is offered its own token and keeps working throughout.
@main
struct FleetDevicePairingCheck {
    @MainActor
    static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-ios-fleet-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func scratchDefaults(_ name: String) -> UserDefaults { UserDefaults(suiteName: scratch.appendingPathComponent(name).path)! }

        let fleet = FakeFleet()
        let mini = try FakeMac(name: "Mac mini", fleet: fleet), studio = try FakeMac(name: "Mac Studio", fleet: fleet, hostID: UUID())
        fleet.members = [studio]
        defer { mini.stop(); studio.stop() }
        let defaults = scratchDefaults("defaults")
        let tokens = HostTokens.memory()
        let hosts = MobileHosts(defaults: defaults, tokens: tokens, device: .init(name: "Ada's iPhone", kind: .iphone),
                                pause: { _ in try await Task.sleep(for: .milliseconds(20)) })

        // A wrong code adds nothing and says what the Mac said.
        fleet.code = "482913"
        do {
            _ = try await hosts.pair(address: "127.0.0.1", port: mini.port, code: "000000")
            fatalError("a wrong code paired")
        } catch RemoteHostClientError.rejected(let code, _) {
            check(code == FleetProtocol.Code.badCode, "the Mac's refusal reaches the device")
        }
        check(hosts.hosts.isEmpty, "nothing added for a wrong code")
        try check(tokens.readDevice() != nil, "the identity is made at once and kept")

        // The right code pairs with the Mac and adds every Mac of its fleet, each with the one token.
        let ids = try await hosts.pair(address: "127.0.0.1", port: mini.port, code: "482913")
        check(ids.count == 2 && hosts.hosts.map(\.name) == ["Mac mini", "Mac Studio"], "the Mac and its fleet are added")
        let identity = try hosts.deviceIdentity()
        for id in ids { try check(tokens.read(id) == identity.token, "every host holds the device's token") }
        check(fleet.accepted == [FleetProtocol.hash(identity.token)] && fleet.devices.first?.name == "Ada's iPhone" && fleet.devices.first?.kind == .iphone,
              "the Mac was sent the hash, the name and the kind, never the token")
        check(!fleet.heard.contains { $0.contains(identity.token) && !$0.contains("\"hello\"") }, "the token only travels in hello")
        let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: MobileHosts.recordsKey)!) as! [[String: Any]]
        check(saved.count == 2 && saved.allSatisfy { Set($0.keys) == ["id", "name", "address", "port", "routes"] }, "records hold no token")
        check(Set(defaults.stringArray(forKey: MobileHosts.ownTokenKey) ?? []) == Set(ids.map(\.uuidString)), "both hosts are marked as on the device's own token")

        // Connected, a device is offered no fleet capability (and so is never offered a token again).
        hosts.setForeground(true)
        try await waitUntil("both Macs connected") { hosts.hosts.allSatisfy { $0.phase == .connected } }
        check(hosts.hosts.allSatisfy { !$0.supports(RemoteProtocol.fleetCapability) && !$0.supports(RemoteProtocol.fleetDevicesCapability) }, "no fleet capability for a device")
        check(fleet.enrollments == 0, "a device on its own token is not offered one")

        // Pairing again with the same Mac updates it: no duplicate.
        fleet.code = "111222"
        let again = try await hosts.pair(address: "127.0.0.1", port: mini.port, code: "111222")
        check(Set(again) == Set(ids) && hosts.hosts.count == 2, "a Mac already held is updated, not added twice")

        // The Mac revoked this identity: the device renews it and pairs again with the same code.
        fleet.revoke(identity.id)
        fleet.code = "333444"
        _ = try await hosts.pair(address: "127.0.0.1", port: mini.port, code: "333444")
        let renewed = try hosts.deviceIdentity()
        check(renewed.id != identity.id && renewed.token != identity.token, "a revoked identity is replaced")
        try check(tokens.read(ids[0]) == renewed.token && fleet.accepted.contains(FleetProtocol.hash(renewed.token)), "the new token is saved and known to the Mac")
        hosts.setForeground(false)

        // An older pairing on the shared token is offered the device's own token, saves it, and carries on.
        let legacyDefaults = scratchDefaults("legacy")
        let legacyTokens = HostTokens.memory()
        let legacy = MobileHosts(defaults: legacyDefaults, tokens: legacyTokens, device: .phone, pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let legacyID = try legacy.add(RemoteHostEntry(name: "Mac mini", address: "127.0.0.1", port: String(mini.port), token: fleet.sharedToken))
        fleet.enrollments = 0
        legacy.setForeground(true)
        let old = legacy.host(legacyID)!
        try await waitUntil("the old pairing connected on the shared token") { old.phase == .connected }
        check(old.supports(RemoteProtocol.fleetDevicesCapability), "a Mac offers devices to a client on the shared token")
        let own = try legacy.deviceIdentity()
        try await waitUntil("the own token saved") { (try? legacyTokens.read(legacyID)) == own.token }
        check(fleet.enrollments == 1 && fleet.accepted.contains(FleetProtocol.hash(own.token)), "the Mac was given the hash of the new token")
        check(Set(legacyDefaults.stringArray(forKey: MobileHosts.ownTokenKey) ?? []) == [legacyID.uuidString], "the host is marked as on its own token")
        check(old.phase == .connected, "the connection in use was not interrupted")

        // The shared token is retired: the next connection uses the device's token and works.
        fleet.sharedTokenRetired = true
        legacy.retry(legacyID)
        try await waitUntil("reconnected on the own token") { old.phase == .connected }
        check(fleet.enrollments == 1, "it is offered once")
        legacy.setForeground(false)

        // A Mac that never answers the offer leaves the shared token in place and the host working.
        let quietFleet = FakeFleet()
        quietFleet.refusesEnrollment = true
        let quiet = try FakeMac(name: "Mac mini", fleet: quietFleet)
        defer { quiet.stop() }
        let quietTokens = HostTokens.memory()
        let quietHosts = MobileHosts(defaults: scratchDefaults("quiet"), tokens: quietTokens, device: .phone, pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let quietID = try quietHosts.add(RemoteHostEntry(name: "Mac mini", address: "127.0.0.1", port: String(quiet.port), token: quietFleet.sharedToken))
        quietHosts.setForeground(true)
        try await waitUntil("the quiet host connected") { quietHosts.host(quietID)?.phase == .connected }
        try await waitUntil("the offer was refused") { quietFleet.enrollments == 1 }
        try await Task.sleep(for: .milliseconds(200))
        try check(quietTokens.read(quietID) == quietFleet.sharedToken, "a refused offer leaves the shared token")
        check(quietHosts.host(quietID)?.phase == .connected, "and the host keeps working")
        quietHosts.setForeground(false)

        // The pairing screen's model: found Macs minus the ones held, a scanned QR chooses its Mac and enters its code.
        let model = MobilePairing(hosts: hosts) { update in
            update([FoundMac(id: "mini", name: "Mac mini", version: "1.9", idHash: FleetProtocol.advertisedIDHash(fleet.hostID), address: "127.0.0.1", port: mini.port),
                    FoundMac(id: "air", name: "MacBook Air", version: "1.9", idHash: "abcdabcdabcdabcd", address: "192.168.1.61", port: 7434)])
            return {}
        }
        model.start()
        try await waitUntil("the found list") { model.found.map(\.id) == ["air"] }
        check(model.mac?.id == "air" && !model.ready, "the only Mac found is the one chosen; a code is still needed")
        model.code = "48 29-13x"
        check(model.code == "482913" && model.ready, "the code keeps six digits")
        check(!model.take(scanned: "https://example.com/?code=123456"), "another QR isn't a pairing code")
        check(model.take(scanned: FleetProtocol.pairLink(code: "654321", advertisedID: "abcdabcdabcdabcd")) && model.code == "654321" && model.picked == "air", "a scanned QR enters its code and chooses its Mac")

        // A pairing link (from Messages or AirDrop, or pasted) names the Mac and its code, whichever edition shared it. Only a device link
        // is taken here; an expired one, a Join link and other text say why not.
        let linkHosts = MobileHosts(defaults: scratchDefaults("link"), tokens: HostTokens.memory(), device: .phone, pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let linking = MobilePairing(hosts: linkHosts) { _ in {} }
        let soon = (Date().timeIntervalSince1970 * 1000 + 60_000).rounded()
        let routes = [FleetReportedRoute(host: "no-such-mac.invalid", kind: .hostname), FleetReportedRoute(host: "127.0.0.1", kind: .lan)]
        let device = FleetPairingLink(purpose: .device, hostID: fleet.hostID, name: "Mac mini", port: mini.port, routes: routes, code: "482913", expiresAt: soon)
        fleet.code = "482913"
        linkHosts.incomingPairingLink = device.url(scheme: "shepherd-nightly").absoluteString
        linking.takeIncomingLink()
        check(linkHosts.incomingPairingLink == nil && linking.link == device && linking.code == "482913" && linking.ready && linking.macName == "Mac mini",
              "an opened link fills in the Mac and its code")
        var join = device
        join.purpose = .join
        linking.read(link: join.url(scheme: "shepherd").absoluteString)
        check(linking.link == nil && linking.linkProblem?.contains("adds a Mac to a fleet") == true, "a Join link isn't for a device")
        var expired = device
        expired.expiresAt = Date().timeIntervalSince1970 * 1000 - 1
        linking.read(link: expired.url(scheme: "shepherd").absoluteString)
        check(linking.link == nil && linking.linkProblem?.hasPrefix("That link has expired") == true, "an expired link pairs nothing")
        linking.read(link: "https://example.com/?c=482913")
        check(linking.link == nil && linking.linkProblem != nil, "other text is not a link")

        // A link whose Mac answers with another id is refused before the code is sent; the right one pairs over the route that answers.
        var stranger = device
        stranger.hostID = UUID()
        let accepted = fleet.accepted.count
        linking.read(link: stranger.url(scheme: "shepherd").absoluteString)
        await linking.pair()
        guard case .failed = linking.phase else { fatalError("FAILED: a link naming another Mac paired") }
        check(linkHosts.hosts.isEmpty && fleet.accepted.count == accepted, "nothing was added or sent for the wrong Mac")
        linking.read(link: device.url(scheme: "shepherd").absoluteString)
        await linking.pair()
        guard case .paired(let names) = linking.phase else { fatalError("FAILED: the link didn't pair: \(linking.phase)") }
        check(names == ["Mac mini", "Mac Studio"] && fleet.accepted.count == accepted + 1 && linking.link == nil && linking.code.isEmpty, "the Mac and its fleet were added over the second route")
        model.stop()
        check(model.found.isEmpty, "stopping clears the list")
        print("PASS: device pairing: the Mac and its fleet added with one token, wrong code, repeated pairing, revoked identity renewed, an older pairing offered its own token and keeping the shared one until it is saved, scanned QR, a pairing link opened, refused and paired")
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

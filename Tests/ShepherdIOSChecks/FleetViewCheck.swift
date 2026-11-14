import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// What a phone does with a fleet: App/iOS/Hosts/MobileHosts.swift connecting to a fake Mac of a fleet over real TCP with a device
// token of its own (tokens in memory, a scratch preferences domain), and ShepherdRemote's `ClientFleet` reading the Macs from it and
// writing the Send work here weight. Built and run by run.sh on macOS. The fake Mac answers what a host answers a device
// (`fleetRead`, `watching`, host settings) and refuses every member's request, so this is the device side: that it is offered the
// view, reads the page, writes the one thing it may, never sends what only a member sends, and hides Fleet when the Mac turns it off.
@main
struct FleetViewCheck {
    static let here = UUID(), mini = UUID(), studio = UUID()

    @MainActor
    static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-ios-fleetview-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let gib: UInt64 = 1 << 30
        let fleet = FakeFleet()
        fleet.hostID = here
        let mac = try FakeMac(name: "MacBook Pro", fleet: fleet)
        fleet.members = [mac]
        defer { mac.stop() }
        fleet.view = FleetSnapshot(
            enabled: true, hostID: here, name: "MacBook Pro",
            peers: [FleetPeerStatus(hostID: mini, name: "Mac mini", pairedAt: 1, link: .connected),
                    FleetPeerStatus(hostID: studio, name: "Mac Studio", pairedAt: 2, link: .offline, lastSeen: 1_790_000_000_000)],
            macs: [FleetMacState(hostID: here, sample: FleetPressureSample(cpuUtilization: 0.72, cpuCount: 12, totalMemoryBytes: 36 * gib,
                                                                            availableMemoryBytes: 9 * gib, onBattery: true, batteryPercent: 41, activeAgents: 3), sampleAge: 1),
                   FleetMacState(hostID: mini, sample: FleetPressureSample(cpuUtilization: 0.18, cpuCount: 14, totalMemoryBytes: 64 * gib,
                                                                            availableMemoryBytes: 41 * gib, activeAgents: 3), sampleAge: 1,
                                 readiness: FleetReadinessReport(model: "Mac mini", missing: [FleetMissingTool(kind: .binary, name: "muse")]))])

        let hosts = MobileHosts(defaults: UserDefaults(suiteName: scratch.appendingPathComponent("defaults").path)!, tokens: HostTokens.memory(),
                                device: .init(name: "Ada's iPhone", kind: .iphone), pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        fleet.code = "482913"
        _ = try await hosts.pair(address: "127.0.0.1", port: mac.port, code: "482913")
        hosts.setForeground(true)
        try await waitUntil("the Mac connected") { hosts.hosts.allSatisfy { $0.phase == .connected } }
        func settingsHosts() -> [SettingsHost] {
            hosts.hosts.map { SettingsHost(id: $0.id, name: $0.name, client: $0.connectedClient, capabilities: $0.capabilities) }
        }

        // A device on its own token is offered the view and none of a member's capabilities.
        let host = hosts.hosts[0]
        check(host.supports(RemoteProtocol.fleetViewCapability) && !host.supports(RemoteProtocol.fleetCapability)
              && !host.supports(RemoteProtocol.fleetPressureCapability) && !host.supports(RemoteProtocol.fleetSyncCapability), "the view, and no member's capability")
        check(ClientFleet.isAvailable(settingsHosts()), "Fleet shows while a Mac serves it")

        // The page: every Mac by name, the room and facts the Mac drew, nothing of "This Mac".
        let model = ClientFleet(hostSettings: ClientHostSettings())
        await model.refresh(settingsHosts(), watching: true)
        let page = model.page
        check(model.phase == .loaded && page.cards.map(\.name) == ["MacBook Pro", "Mac mini", "Mac Studio"], "the page names the Macs: \(page.cards.map(\.name))")
        check(page.nextGoesTo == "Mac mini" && page.cards[1].room.text == "Most room" && page.cards[0].room.text == "Little room", "room and where work goes next")
        check(page.cards[0].facts(.phone) == "CPU 72% · 9.0 GB free · battery 41%", "a row's facts: \(page.cards[0].facts(.phone))")
        check(page.cards[1].ready.text == "muse CLI isn’t installed", "readiness reaches the phone")
        check(page.cards[2].status == .asleep && page.footer.detail == "1 asleep", "a Mac asleep, and the sidebar's words")
        check(fleet.watching == [true], "the page on screen asked the Mac to sample, in the same request that read it")

        // The one write: the weight, as the Mac's own host setting, shown at once and read back.
        let write = model.choose(.manualOnly, for: studio, settingsHosts())
        check(model.page.cards[2].weight == .manualOnly, "shown before the Mac answers")
        await write?.value
        check(fleet.changes == [.fleetWeight(hostID: studio, weight: .manualOnly)], "exactly that change reached the Mac: \(fleet.changes)")
        check(fleet.weights[FleetSendWeight.settingKey(hostID: studio)] == .manualOnly && model.problem == nil, "the Mac holds it")

        // The Mac's fleet id is kept with the pairing, so the Fleet screen finds it while it is away; Forget clears it.
        let defaults = hosts.defaults
        check(hosts.hosts[0].fleetID == here, "the pairing holds the Mac's fleet id")
        check((defaults.dictionary(forKey: MobileHosts.fleetIDKey) as? [String: String]) == [hosts.hosts[0].id.uuidString: here.uuidString], "kept across launches")
        let reopened = MobileHosts(defaults: defaults, tokens: HostTokens.memory(), device: .init(name: "Ada's iPhone", kind: .iphone))
        check(reopened.hosts.first?.fleetID == here, "a new launch knows it before connecting")
        let rows = FleetDeviceList.rows(page: model.page, held: reopened.hosts.map {
            FleetHeldMac(configID: $0.id, fleetID: $0.fleetID, name: $0.name, link: .offline)
        })
        check(rows.map(\.card.name) == ["MacBook Pro", "Mac mini", "Mac Studio"] && rows.compactMap(\.held) == [hosts.hosts[0].id], "the away Mac is one row with the fleet's card, not two: \(rows.map(\.card.name))")

        // Leaving the screen stops the sampling the Mac was asked for.
        await model.stopWatching(settingsHosts())
        check(fleet.watching == [true, false], "leaving the page told the Mac")

        // Nothing a member sends was ever sent.
        let sentKinds = fleet.heard.compactMap { line -> String? in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
            return object["type"] as? String ?? object["kind"] as? String
        }
        check(sentKinds.contains("fleetAction") && sentKinds.contains("hostSettings"), "the kinds are read from what was sent: \(sentKinds)")
        for forbidden in ["fleetSync", "fleetPressure", "fleetReadiness", "fleetPressureNow", "fleetIntroduce", "fleetRevoke"] {
            check(!sentKinds.contains(forbidden), "a phone never sends \(forbidden)")
        }

        // The Mac turns Fleet off: it says so, and the phone hides Fleet and shows that it is off.
        fleet.view = nil
        mac.push(capabilities: [RemoteProtocol.nativeThreadCapability, RemoteProtocol.hostSettingsCapability])
        try await waitUntil("the capability to be withdrawn") { !hosts.hosts[0].supports(RemoteProtocol.fleetViewCapability) }
        check(!ClientFleet.isAvailable(settingsHosts()), "Fleet hides once no Mac serves it")
        // Forget this Mac: the pairing, its token and its fleet id go; a Mac the fleet still names has no pairing left.
        let forgotten = hosts.hosts[0].id
        try hosts.forget(forgotten)
        check(hosts.hosts.isEmpty && (defaults.dictionary(forKey: MobileHosts.fleetIDKey) as? [String: String])?.isEmpty == true, "forgotten, with its fleet id")
        check(FleetDeviceList.rows(page: model.page, held: []).allSatisfy { $0.held == nil && !$0.canRetry }, "the fleet's Macs remain, with nothing to forget")
        hosts.setForeground(false)
        print("PASS: a phone is offered the fleet view, reads the Macs and their room, writes the weight as a host setting, sends nothing a member sends, and hides Fleet when the Mac turns it off, keeps each Mac's fleet id with its pairing and joins it to the fleet's card, and forgets a Mac")
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

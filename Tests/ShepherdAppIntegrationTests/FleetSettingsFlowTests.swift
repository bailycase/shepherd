import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ Fleet as the host's client: the Experiments switch starts and stops the host's
/// fleet, the page's model pairs and removes Macs through the host, and a Mac the app already
/// reached with the shared token becomes a peer. Each `FleetApp` is a scratch host served as
/// `Shepherd --host` serves it (`ShepherdHost.serveSettings`) with its app's model on `host.sock`.
@Suite("Settings ▸ Fleet", .mainActorExclusive)
@MainActor
struct FleetSettingsFlowTests {
    struct TimedOut: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    /// Polls a main actor condition that reads the host again each time (`eventually` takes none that awaits one).
    static func waitFor(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + defaultWaitTimeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut(what: what)
    }

    @MainActor
    final class FleetApp {
        let host: ScratchServer
        let settings: AppSettings
        let client: RemoteHostClient
        let model = FleetSettingsModel()
        let token: String
        let port: UInt16?
        var server: SessionServer { host.server }

        /// `fleet: false` leaves Fleet off, as a fresh install is; `serving` turns Settings ▸ Remote's Serve this Mac on.
        init(_ name: String, fleet: Bool = true, serving: Bool = false, dir: URL? = nil) async throws {
            let host = try ScratchServer(dir: dir)
            host.server.configureFleet(name: name, advertises: false)
            let settings = AppSettings(store: ScratchDefaults())
            // Ephemeral: never the edition's own port, which a running Shepherd may hold.
            settings.remoteListenerPort = 0
            settings.fleetEnabled = fleet
            settings.remoteListenerEnabled = serving
            HostSettingsMapping.serve(on: host.server, settings: settings)
            let port = ShepherdHost.serveSettings(settings, on: host.server)
            let tokenURL = host.dir.appendingPathComponent("remote-token")
            let socket = host.dir.appendingPathComponent("h.sock").path
            try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let client = RemoteHostClient(localSocket: socket)
            _ = try await client.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            (self.host, self.settings, self.client, self.token, self.port) = (host, settings, client, token, port)
            model.host = { client }
        }

        func stop() {
            client.disconnect()
            host.stop()
        }

        var found: FoundMac { FoundMac(id: name, name: name, version: "1.9", idHash: nil, address: "127.0.0.1", port: port) }
        var name: String { host.dir.lastPathComponent }
    }

    @Test func theExperimentSwitchStartsTheHostsFleetAndOpensItsListenerWithRemoteOff() async throws {
        let app = try await FleetApp("MacBook Pro", fleet: false)
        defer { app.stop() }
        #expect(app.port == nil && !app.settings.remoteListenerEnabled)
        await app.model.refresh()
        #expect(!app.model.snapshot.enabled && app.model.rows.isEmpty, "Fleet is off: the page has nothing")

        app.settings.fleetEnabled = true
        try await Self.waitFor("the host's fleet to start and its listener to open") {
            await app.model.refresh()
            return app.model.snapshot.enabled && app.model.snapshot.port != nil
        }
        let id = try #require(app.model.snapshot.hostID)
        #expect(app.model.snapshot.name == "MacBook Pro" && app.model.rows.map(\.title) == ["This Mac"])
        #expect(!app.settings.remoteListenerEnabled, "Serve this Mac's own switch stays off")
        let phone = RemoteHostClient()
        _ = try await phone.connect(host: "127.0.0.1", port: try #require(app.model.snapshot.port), token: app.token, clientName: "peer")
        #expect(phone.capabilities.contains(RemoteProtocol.fleetCapability) && phone.hostID == id)
        phone.disconnect()

        // Off again: the links and the listener end, the pairing file stays, and on again it is the same Mac.
        app.settings.fleetEnabled = false
        try await Self.waitFor("the host's fleet to stop") {
            await app.model.refresh()
            return !app.model.snapshot.enabled
        }
        app.settings.fleetEnabled = true
        try await Self.waitFor("the same fleet to come back") {
            await app.model.refresh()
            return app.model.snapshot.hostID == id
        }
    }

    @Test func aClientTurnsFleetOnAndOffThroughTheHostsSettings() async throws {
        let app = try await FleetApp("MacBook Pro", fleet: false)
        defer { app.stop() }
        #expect(try await app.client.hostSettings().fleetEnabled == false)
        let on = try await app.client.hostSettings(.change(.fleetEnabled(true)))
        #expect(on.fleetEnabled && app.settings.fleetEnabled)
        try await Self.waitFor("the host's fleet to start") {
            await app.model.refresh()
            return app.model.snapshot.enabled
        }
        #expect(app.client.capabilities.contains(RemoteProtocol.fleetExperimentCapability))
    }

    @Test func twoAppsPairThroughTheirModelsAndEachListsTheOther() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        await b.model.startJoin()
        let code = try #require(b.model.join?.code)
        #expect(code.count == FleetProtocol.codeLength)

        #expect(await a.model.pair(with: b.found, code: code))
        #expect(a.model.pairing == .idle)
        try await Self.waitFor("both Macs to list each other as connected") {
            await a.model.refresh(); await b.model.refresh()
            return a.model.rows.map(\.state) == [.thisMac, .connected] && b.model.rows.map(\.state) == [.thisMac, .connected]
        }
        #expect(a.model.rows.map(\.title) == ["This Mac", "Mac mini"] && b.model.rows.map(\.title) == ["This Mac", "MacBook Pro"])
        #expect(b.model.join == nil && b.model.joinEnd == .joined("MacBook Pro"), "the Join screen learns who joined")
        #expect(a.model.rows[1].hostID != nil && a.model.rows[0].hostID == nil, "This Mac can't be removed")

        // Removing it from either Mac empties both.
        await a.model.remove(try #require(a.model.rows[1].hostID))
        try await Self.waitFor("both Macs to drop each other") {
            await b.model.refresh()
            return a.model.rows.count == 1 && b.model.rows.count == 1
        }
    }

    @Test func aWrongCodeSaysHowManyTriesAreLeftAndKeepsTheSheetOpen() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        await b.model.startJoin()
        let code = try #require(b.model.join?.code)
        let wrong = code == "000000" ? "111111" : "000000"
        #expect(await a.model.pair(with: b.found, code: wrong) == false)
        #expect(a.model.pairing == .failed("That code isn't right. 4 tries left."))
        await a.model.refresh()
        #expect(a.model.rows.count == 1, "nothing paired")
        #expect(await a.model.pair(with: b.found, code: code), "the right code still works")
    }

    @Test func addAMacListsOnlyMacsThatAreNeitherThisOneNorAlreadyPaired() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        let own = FoundMac(id: "own", name: "MacBook Pro", idHash: FleetProtocol.advertisedIDHash(try #require(a.model.snapshot.hostID)),
                           address: "127.0.0.1", port: 1)
        let imac = FoundMac(id: "imac", name: "iMac", version: "1.9", idHash: "abcdabcdabcdabcd", address: "192.168.1.52", port: 7434)
        a.model.browse = { update in update([own, imac]); return {} }
        a.model.startFinding()
        try await Self.waitFor("the list to hold the iMac only") { a.model.found == [imac] }

        // After pairing with the iMac's stand-in, it is gone from the list too.
        await b.model.startJoin()
        #expect(await a.model.pair(with: b.found, code: try #require(b.model.join?.code)))
        let paired = try #require(a.model.snapshot.peers.first?.hostID)
        let mini = FoundMac(id: "mini", name: "Mac mini", idHash: FleetProtocol.advertisedIDHash(paired), address: "127.0.0.1", port: 2)
        a.model.browse = { update in update([own, imac, mini]); return {} }
        a.model.startFinding()
        try await Self.waitFor("the paired Mac to leave the list") { a.model.found == [imac] }
        a.model.stopFinding()
        #expect(a.model.found.isEmpty)
    }

    @Test func aMacTheAppAlreadyReachedWithTheSharedTokenBecomesAPeerAndIsMarkedFleetManaged() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        let defaults = ScratchDefaults()
        let store = RemoteHostStore(defaults: defaults, connects: false)
        store.addHost(name: "mini", host: "127.0.0.1", port: try #require(b.port), token: b.token)
        let config = try #require(store.hosts.first)
        let off = try await FleetApp("Mac Studio", fleet: false, serving: true)
        defer { off.stop() }
        store.addHost(name: "studio", host: "127.0.0.1", port: try #require(off.port), token: off.token)

        let legacy = store.hosts.map { FleetLegacyHost(id: $0.id, name: $0.name, host: $0.host, port: $0.port, token: $0.token) }
        let outcomes = await a.model.adopt(legacy)
        let established = outcomes.compactMap { adoption -> UUID? in if case .established = adoption.outcome { adoption.id } else { nil } }
        #expect(established == [config.id])
        #expect(outcomes.contains { $0.outcome == .notFleet }, "a Mac with Fleet off is left as it was")
        for id in established { store.markFleetManaged(id: id) }

        #expect(store.hosts.map(\.fleetManaged) == [true, false])
        let reloaded = RemoteHostStore(defaults: defaults, connects: false)
        #expect(reloaded.hosts.first?.fleetManaged == true && reloaded.hosts.first?.bindingID == config.bindingID, "the binding survives")
        try await Self.waitFor("the peer to connect") {
            await a.model.refresh()
            return a.model.rows.map(\.state) == [.thisMac, .connected]
        }
    }

    // MARK: The Fleet page

    /// Two paired Macs, the first one's page model wired as the app wires it, and the host told the page is on screen.
    @Test func theFleetPageShowsEachMacWithRealReadingsAndTheHostSamplesOnlyWhileItIsOnScreen() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        let page = FleetPageModel()
        page.weight = { [settings = a.settings] in settings.fleetWeight(of: $0) }
        page.setWeight = { [settings = a.settings] in settings.setFleetWeight($0, of: $1) }
        a.model.onSnapshot = { page.update($0) }
        a.settings.onFleetWeightsChange = { page.recompute() }
        await b.model.startJoin()
        #expect(await a.model.pair(with: b.found, code: try #require(b.model.join?.code)))

        // Not on screen: the host holds links but nobody asked for the page, so there is no reading of this Mac.
        try await Self.waitFor("the page to list both Macs") {
            await a.model.refresh()
            return page.page.cards.map(\.name) == ["This Mac", "Mac mini"]
        }

        await a.model.watch(true)
        try await Self.waitFor("both Macs to show a reading and the report") {
            await a.model.refresh()
            let cards = page.page.cards
            return cards.count == 2 && cards.allSatisfy { $0.cpu != nil && $0.memory != nil && !$0.hardware.isEmpty } && cards[1].statusText == "Connected"
        }
        let (here, mini) = (page.page.cards[0], page.page.cards[1])
        #expect(here.statusText == "This Mac" && here.isThisMac && mini.id == b.model.snapshot.hostID)
        // Real readings of a machine that may be busy: any room word is right, a blank one is not.
        #expect(["Most room", "Some room", "Little room", "Room to spare", "No room"].contains(here.room.text), "\(here.room.text)")
        #expect(page.page.footer.dots == [.thisMac, .connected] && page.page.footer.detail == "All awake")

        // Send work here writes the setting the host settings and Fleet's own keys share.
        let miniID = try #require(b.model.snapshot.hostID)
        page.choose(.manualOnly, for: miniID)
        #expect(a.settings.fleetWeights == [FleetSendWeight.settingKey(hostID: miniID): .manualOnly])
        #expect(page.page.cards[1].weight == .manualOnly && page.page.nextGoesTo != "Mac mini", "Auto no longer picks it")

        // Retry on a Mac that is connected changes nothing; the page stays as it was.
        await a.model.reconnect(miniID)
        #expect(a.model.snapshot.peers.first?.link == .connected)
        await a.model.watch(false)
    }

    @Test func aMacThatGoesAwayShowsAsleepWithWhenItWasSeenAndNothingMovesToIt() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop() }
        let page = FleetPageModel()
        a.model.onSnapshot = { page.update($0) }
        await b.model.startJoin()
        #expect(await a.model.pair(with: b.found, code: try #require(b.model.join?.code)))
        await a.model.watch(true)
        try await Self.waitFor("the Mac to show as connected") {
            await a.model.refresh()
            return page.page.cards.count == 2 && page.page.cards[1].statusText == "Connected"
        }
        b.stop()
        try await Self.waitFor("the Mac to show as asleep") {
            await a.model.refresh()
            return page.page.cards.count == 2 && page.page.cards[1].statusText == "Asleep"
        }
        let asleep = page.page.cards[1]
        #expect(asleep.canRetry && asleep.room.text == "Not counted" && asleep.cpu == nil && asleep.ready.text == "Catches up when it wakes")
        #expect(asleep.power.text.hasPrefix("Last seen ") && page.page.footer.detail == "1 asleep")
        #expect(page.page.nextGoesTo != "Mac mini", "an asleep Mac is never picked")
        #expect(page.page.summary.hasPrefix("2 Macs · 1 asleep"))
    }
}

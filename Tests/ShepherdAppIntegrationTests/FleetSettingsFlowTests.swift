import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ Fleet as the host's client: a fresh host listens on nothing and opens its listener as a Mac pairs or a code shows, the
/// page's model pairs and removes Macs through the host, the app's connections follow the fleet, and a Mac this app was a client of
/// is a row to add to the fleet. Each `FleetApp` is a scratch host served as
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
        var server: SessionServer { host.server }
        /// The port the host's listener is bound to now: nil on a fresh host, which listens on nothing until the fleet needs it.
        var port: UInt16? { host.server.remoteListenerPort }

        /// `serving` turns Serve this Mac on.
        init(_ name: String, serving: Bool = false, dir: URL? = nil, configure: (SessionServer) -> Void = { _ in }) async throws {
            let host = try ScratchServer(dir: dir)
            host.server.configureFleet(name: name, advertises: false)
            configure(host.server)
            let settings = AppSettings(store: ScratchDefaults())
            // Ephemeral: never the edition's own port, which a running Shepherd may hold.
            settings.remoteListenerPort = 0
            settings.remoteListenerEnabled = serving
            HostSettingsMapping.serve(on: host.server, settings: settings)
            ShepherdHost.serveSettings(settings, on: host.server)
            let tokenURL = host.dir.appendingPathComponent("remote-token")
            let socket = host.dir.appendingPathComponent("h.sock").path
            try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let client = RemoteHostClient(localSocket: socket)
            _ = try await client.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            (self.host, self.settings, self.client, self.token) = (host, settings, client, token)
            model.host = { client }
        }

        func stop() {
            client.disconnect()
            host.stop()
        }

        var found: FoundMac { FoundMac(id: name, name: name, version: "1.9", idHash: nil, address: "127.0.0.1", port: port) }
        var name: String { host.dir.lastPathComponent }
    }

    @Test func aFreshHostListensOnNothingAndOpensItsListenerForACodeAndForAPairedMac() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        // Fleet needs no switch: the page has the Mac, and nothing listens until a Mac, a device or a code needs it.
        #expect(a.model.snapshot.enabled && a.model.loaded && a.model.rows.map(\.title) == ["This Mac"])
        #expect(a.port == nil && a.model.snapshot.port == nil && !a.settings.remoteListenerEnabled)

        // A code showing opens it, with Serve this Mac's own switch still off; closing the screen closes it.
        await b.model.startJoin()
        let code = try #require(b.model.join?.code)
        let port = try #require(b.port, "the code is shown once the listener it is entered against is open")
        #expect(b.model.snapshot.port == port && !b.settings.remoteListenerEnabled)
        let phone = RemoteHostClient()
        _ = try await phone.connect(host: "127.0.0.1", port: port, token: b.token, clientName: "peer")
        #expect(phone.capabilities.contains(RemoteProtocol.fleetCapability) && phone.hostID == b.model.snapshot.hostID)
        phone.disconnect()

        // A Mac that pairs keeps it open on both sides, though the code is spent, and the one that entered it opens its own.
        #expect(await a.model.pair(with: b.found, code: code))
        try await Self.waitFor("both Macs to listen and list each other") {
            await a.model.refresh(); await b.model.refresh()
            return a.port != nil && b.port != nil && a.model.rows.count == 2 && b.model.rows.count == 2
        }

        // Removing the last Mac closes what only the fleet held open.
        await a.model.remove(try #require(a.model.rows[1].hostID))
        try await Self.waitFor("both Macs to stop listening") { a.port == nil && b.port == nil }
        #expect(!a.settings.remoteListenerEnabled && !b.settings.remoteListenerEnabled)
    }

    @Test func serveThisMacKeepsTheListenerOpenWithNoMacPairedAndANeedEndingLeavesItOpen() async throws {
        let app = try await FleetApp("MacBook Pro", serving: true)
        defer { app.stop() }
        let port = try #require(app.port, "Serve this Mac opens it")
        await app.model.startJoin()
        #expect(app.port == port)
        await app.model.stopJoin()
        try await Self.waitFor("the host to hear the code window end") { await app.model.refresh(); return app.model.snapshot.join == nil }
        #expect(app.port == port, "the switch is the person's own reason to listen")
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

    /// iCloud as a dictionary: Add a Mac with no Mac picked asks the host, which finds where the code was shown.
    final class Cloud: FleetRendezvousStore, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [FleetRendezvousKey: FleetRendezvousRecord] = [:]
        private let failure: FleetRendezvousError?
        init(failure: FleetRendezvousError? = nil) { self.failure = failure }
        func put(_ record: FleetRendezvousRecord) async throws { try lock.withLock { if let failure { throw failure }; records[record.key] = record } }
        func fetch(_ key: FleetRendezvousKey) async throws -> FleetRendezvousRecord? { try lock.withLock { if let failure { throw failure }; return records[key] } }
        func delete(_ key: FleetRendezvousKey) async throws { try lock.withLock { if let failure { throw failure }; records[key] = nil } }
    }

    static func viaICloud(_ cloud: Cloud) -> (SessionServer) -> Void {
        { server in server.configureFleetRendezvous(store: cloud, routes: { port in [FleetRoute(host: "127.0.0.1", port: port, kind: .lan, learned: false)] }, lookupInterval: 0) }
    }

    @Test func aCodeTypedWithNoMacPickedPairsThroughICloudAndASheetOnAnOlderHostIsNotOffered() async throws {
        let cloud = Cloud()
        let a = try await FleetApp("MacBook Pro", configure: Self.viaICloud(cloud)), b = try await FleetApp("Mac mini", configure: Self.viaICloud(cloud))
        defer { a.stop(); b.stop() }
        #expect(!a.model.findsByCode, "until the host has said what it can do")
        await a.model.refresh()
        #expect(a.model.findsByCode)
        await b.model.startJoin()
        let code = try #require(b.model.join?.code)

        #expect(await a.model.pairByCode(code))
        #expect(a.model.pairing == .idle)
        try await Self.waitFor("both Macs to list each other as connected") {
            await a.model.refresh(); await b.model.refresh()
            return a.model.rows.map(\.state) == [.thisMac, .connected] && b.model.rows.map(\.state) == [.thisMac, .connected]
        }
        #expect(b.model.joinEnd == .joined("MacBook Pro"))
    }

    @Test func aCodeNobodyShowsAndNoICloudEachSaySoInTheSheet() async throws {
        let a = try await FleetApp("MacBook Pro", configure: Self.viaICloud(Cloud()))
        let signedOut = try await FleetApp("Mac studio", configure: Self.viaICloud(Cloud(failure: .noAccount)))
        defer { a.stop(); signedOut.stop() }
        #expect(!(await a.model.pairByCode("482913")))
        guard case .failed(let none) = a.model.pairing else { Issue.record("a code nobody shows paired"); return }
        #expect(none.hasPrefix("No Mac is showing that code"))

        #expect(!(await signedOut.model.pairByCode("482913")))
        #expect(signedOut.model.pairing == .failed("Not signed in to iCloud: use a pairing link"))
        #expect(signedOut.model.rows.map(\.title) == [] || signedOut.model.rows.map(\.title) == ["This Mac"], "nothing was added")
    }

    /// What the Mac's app does with sync: a setting changed on one Mac's Settings is applied by the other's own
    /// `AppSettings` (so its pi files and running agents follow as for a change made there), and the page says where sync stands.
    @Test func aSettingChangedOnOneMacReachesTheOthersAppSettingsAndThePageSaysSoInSync() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        await b.model.startJoin()
        #expect(await a.model.pair(with: b.found, code: try #require(b.model.join?.code)))

        a.settings.defaultThinking = .high
        a.settings.worktreeFetchBeforeCreate = false
        try await Self.waitFor("the mini's settings to follow") { b.settings.defaultThinking == .high && !b.settings.worktreeFetchBeforeCreate }
        // And the other way, later: the mini's own change wins, on both.
        b.settings.defaultThinking = .low
        try await Self.waitFor("the MacBook Pro to follow the mini") { a.settings.defaultThinking == .low }
        #expect(!a.settings.worktreeFetchBeforeCreate, "nothing else was reverted")

        // The page's sync line: both Macs hold the same.
        try await Self.waitFor("the sync line to say both are in sync") {
            await a.model.refresh()
            return a.model.syncLine == FleetSyncLine(tone: .inSync, lead: "In sync on This Mac and Mac mini")
        }
        // Per Mac switches stay per Mac.
        a.settings.designToolEnabled = true
        try await Self.waitFor("A's own switch to settle") { a.settings.designToolEnabled }
        #expect(!b.settings.designToolEnabled && !b.settings.projectsEnabled)
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

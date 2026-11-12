import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Sign-ins in a fleet between real scratch hosts (slice 2c). Each Mac has its own pi home, so what
/// one Mac's pi writes into `auth.json` or `mcp-auth.json` is what the other writes through its own
/// lock, and nothing is shared but the wire. Every credential is a made up string.
@Suite("Fleet credentials sync", .integrationTimeLimit)
struct FleetCredentialsSyncTests {
    typealias Mac = FleetSyncTests.Mac

    static let acme = "acme-ai"
    static let widgets = "widgets"
    static let notionKey = "mcp__notion|https://mcp.notion.com/mcp"

    static func oauth(_ generation: Int) -> [String: Any] {
        ["type": "oauth", "access": "fake-access-\(generation)", "refresh": "fake-refresh-\(generation)", "expires": 1_790_000_000_000 + generation]
    }

    static func server(_ generation: Int) -> [String: Any] {
        ["tokens": ["access_token": "fake-mcp-access-\(generation)", "refresh_token": "fake-mcp-refresh-\(generation)"], "clientInfo": ["client_id": "fake-client"]]
    }

    // MARK: What pi does on a Mac

    static func auth(_ mac: Mac) -> URL { mac.server.pi.files.directory.appendingPathComponent("auth.json") }
    static func mcpAuth(_ mac: Mac) -> URL { mac.server.pi.files.directory.appendingPathComponent("mcp-auth.json") }

    /// pi writes one key of its file under its own lock, the way a sign-in or a refresh does.
    static func piWrites(_ key: String, _ value: [String: Any]?, in file: URL) throws {
        _ = try PiSettingsFile(url: file).update { object in
            if let value { object[key] = value } else { object.removeValue(forKey: key) }
            return []
        }
    }

    static func contents(_ file: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? [:]
    }

    static func refresh(_ mac: Mac, _ provider: String = acme) -> String? {
        (contents(auth(mac))[provider] as? [String: Any])?["refresh"] as? String
    }

    static func mcpRefresh(_ mac: Mac) -> String? {
        ((contents(mcpAuth(mac))[notionKey] as? [String: Any])?["tokens"] as? [String: Any])?["refresh_token"] as? String
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    /// Fleet is switched on by the host asynchronously: a Mac is asked to pair only once it says it is on.
    static func enabled(_ macs: Mac...) async throws {
        for mac in macs { try await eventually("\(mac.name) to have Fleet on") { try await mac.read().enabled } }
    }

    static func pair() async throws -> (Mac, Mac) {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        do {
            try await enabled(a, b)
            try await a.pair(with: b)
            try await a.waitForLink(to: b)
            try await b.waitForLink(to: a)
        } catch {
            a.stop(); b.stop()
            throw error
        }
        return (a, b)
    }


    // MARK: A sign-in on one Mac, the other has it

    @Test func aSignInOnOneMacAppearsOnTheOtherAndStaysPrivate() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try await eventually("Mac mini's auth.json to hold the sign-in") { Self.refresh(b) == "fake-refresh-1" }
        #expect(Self.mode(Self.auth(b)) == 0o600, "pi's file stays private")
        let there = try #require(Self.contents(Self.auth(b))[Self.acme] as? [String: Any])
        #expect(there["access"] as? String == "fake-access-1" && there["type"] as? String == "oauth")

        // An API key and an MCP server's sign-in travel the same way, each into its own file.
        try Self.piWrites(Self.widgets, ["type": "api_key", "key": "fake-key"], in: Self.auth(a))
        try Self.piWrites(Self.notionKey, Self.server(1), in: Self.mcpAuth(a))
        try await eventually("Mac mini to hold the key and the server's sign-in") {
            (Self.contents(Self.auth(b))[Self.widgets] as? [String: Any])?["key"] as? String == "fake-key" && Self.mcpRefresh(b) == "fake-mcp-refresh-1"
        }
        #expect(Self.mode(Self.mcpAuth(b)) == 0o600)

        // Signing out on one Mac signs out the other, and only that provider.
        try Self.piWrites(Self.acme, nil, in: Self.auth(a))
        try await eventually("Mac mini to be signed out of acme-ai") { Self.contents(Self.auth(b))[Self.acme] == nil }
        #expect(Self.contents(Self.auth(b))[Self.widgets] != nil)

        // No echo: both settle and neither made an op for what the other wrote.
        try await eventually("both Macs to settle") {
            try await [a.syncStatus(), b.syncStatus()].allSatisfy { $0.peers.allSatisfy { $0.state == .inSync } }
        }
        #expect(a.server.fleetSyncWinner("credential:\(Self.acme)") == b.server.fleetSyncWinner("credential:\(Self.acme)"))
    }

    // MARK: A rotation

    @Test func aRefreshRotationOnOneMacIsImportedAndTheOtherWaitsForItBeforeStartingPi() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try await eventually("Mac mini to hold generation 1") { Self.refresh(b) == "fake-refresh-1" }

        // pi on the MacBook refreshes: the token it had is no longer good anywhere. The Mac mini is about to
        // start pi, before the MacBook's watcher has read the file: the launch asks, and has the new one when it goes on.
        try Self.piWrites(Self.acme, Self.oauth(2), in: Self.auth(a))
        await b.server.fleetCredentialFence()
        #expect(Self.refresh(b) == "fake-refresh-2", "pi on the Mac mini would have started with a token the MacBook had rotated away")

        // Again, the other way round: a refresh on the Mac mini reaches the MacBook before its pi starts.
        try Self.piWrites(Self.acme, Self.oauth(3), in: Self.auth(b))
        await a.server.fleetCredentialFence()
        #expect(Self.refresh(a) == "fake-refresh-3")

        // The chain of generations is in the log: each refresh is one op of one unit, the older ones in history.
        let unit = "credential:\(Self.acme)"
        #expect(a.server.fleetSyncWinner(unit) == b.server.fleetSyncWinner(unit))
        #expect(a.server.fleetSyncHistory(unit).count == 2)
    }

    @Test func anMCPServersRefreshGetsTheSameTreatment() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.piWrites(Self.notionKey, Self.server(1), in: Self.mcpAuth(a))
        try await eventually("Mac mini to hold the server's sign-in") { Self.mcpRefresh(b) == "fake-mcp-refresh-1" }
        try Self.piWrites(Self.notionKey, Self.server(2), in: Self.mcpAuth(a))
        await b.server.fleetCredentialFence()
        // (The fence's own proof is the provider test above; here the server's file is the same unit, so it follows.)
        try await eventually("Mac mini to hold the server's rotation") { Self.mcpRefresh(b) == "fake-mcp-refresh-2" }

        // A sign-in under way (a verifier, no tokens yet) is that Mac's own business.
        try Self.piWrites("mcp__linear|https://mcp.linear.app/mcp", ["codeVerifier": "fake-verifier"], in: Self.mcpAuth(a))
        await b.server.fleetCredentialFence()
        #expect(Self.contents(Self.mcpAuth(b))["mcp__linear|https://mcp.linear.app/mcp"] == nil)
    }

    @Test func aMacThatCannotBeCaughtUpIsWaitedForOnlyBrieflyAndNotAgainAtOnce() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try await eventually("Mac mini to hold generation 1") { Self.refresh(b) == "fake-refresh-1" }

        // The MacBook can't push to the Mac mini (its link for pushing is down), though it answers a question.
        let bID = try #require(try await b.read().hostID)
        a.server.queue.sync { a.server.fleet?.syncEngine.linkDown(peer: bID) }
        try Self.piWrites(Self.acme, Self.oauth(2), in: Self.auth(a))
        let engine = try #require(b.server.queue.sync { b.server.fleet?.syncEngine })

        let clock = ContinuousClock()
        let first = await clock.measure { await engine.catchUpCredentials(patience: 0.4) }
        #expect(first >= .milliseconds(300) && first < .seconds(3), "it waited for the patience it was given, then went on")
        #expect(Self.refresh(b) == "fake-refresh-1", "with what the Mac mini has")
        let second = await clock.measure { await engine.catchUpCredentials(patience: 0.4) }
        #expect(second < .milliseconds(250), "a Mac that failed to catch this one up is not waited for again at once")
    }

    @Test func withFleetOffNoSignInIsReadAndNothingWaits() async throws {
        let a = try await Mac("MacBook Pro", enable: false)
        defer { a.stop() }
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        let before = try Data(contentsOf: Self.auth(a))
        let took = await ContinuousClock().measure { await a.server.fleetCredentialFence() }
        #expect(took < .milliseconds(250))
        #expect(try Data(contentsOf: Self.auth(a)) == before)
        #expect(!FileManager.default.fileExists(atPath: a.host.dir.appendingPathComponent("fleet/store").path), "no store until Fleet is on")
    }

    // MARK: pi's own writes are never clobbered

    @Test func aWritePiMadeToAnotherProviderIsNotClobberedByAnArrivingSignIn() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.piWrites("local-only", ["type": "api_key", "key": "fake-local"], in: Self.auth(b))
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try Self.piWrites(Self.widgets, ["type": "api_key", "key": "fake-widgets"], in: Self.auth(b))
        try await eventually("Mac mini to hold the arriving sign-in") { Self.refresh(b) == "fake-refresh-1" }
        let there = Self.contents(Self.auth(b))
        #expect(Set(there.keys) == ["local-only", Self.widgets, Self.acme], "what pi wrote on the Mac mini stands beside what arrived")

        // What pi on the Mac mini wrote reaches the MacBook, and its own sign-in is as it was.
        try await eventually("the MacBook to hold what the Mac mini's pi wrote") {
            Set(Self.contents(Self.auth(a)).keys) == ["local-only", Self.widgets, Self.acme] && Self.refresh(a) == "fake-refresh-1"
        }
    }

    @Test func aLocalEditNotReadYetIsAnOpBeforeAnArrivingSignInWritesOverIt() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try await eventually("Mac mini to hold generation 1") { Self.refresh(b) == "fake-refresh-1" }
        // Both rotate at about the same time: one wins by the clock, and both Macs end on the same one.
        try Self.piWrites(Self.acme, Self.oauth(2), in: Self.auth(a))
        try Self.piWrites(Self.acme, Self.oauth(3), in: Self.auth(b))
        try await eventually("both Macs to hold the same generation") {
            let (one, other) = (Self.refresh(a), Self.refresh(b))
            return one != nil && one == other && one != "fake-refresh-1"
        }
        let unit = "credential:\(Self.acme)"
        let kept = Set(a.server.fleetSyncHistory(unit).map(\.change))
        #expect(a.server.fleetSyncWinner(unit) == b.server.fleetSyncWinner(unit))
        #expect(!kept.isEmpty, "the one that lost is in history")
    }

    // MARK: Before the Macs meet, and the files the store keeps

    @Test func twoMacsWithDifferentSignInsKeepTheReferencesAndTheOthersGoesToHistoryPrivately() async throws {
        let a = try await Mac("MacBook Pro", enable: false), b = try await Mac("Mac mini", enable: false)
        defer { a.stop(); b.stop() }
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try Self.piWrites(Self.acme, Self.oauth(9), in: Self.auth(b))
        a.enable()
        // The Mac where Fleet was first switched on is the reference.
        try await eventually("the MacBook to hold its sign-in as a seed") { a.server.fleetSyncWinner("credential:\(Self.acme)") != nil }
        b.enable()
        try await Self.enabled(a, b)
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        try await eventually("the Mac mini to take the reference's sign-in") { Self.refresh(b) == "fake-refresh-1" }
        #expect(Self.refresh(a) == "fake-refresh-1")
        let history = b.server.fleetSyncHistory("credential:\(Self.acme)")
        #expect(history.contains { entry in
            if case .value(let text) = entry.change { return text.contains("fake-refresh-9") }
            return false
        }, "the Mac mini's own copy is kept")

        // Everything the store keeps is private to the user: logs, blobs and history.
        for mac in [a, b] {
            let root = try #require(mac.server.fleetStoreDirectory)
            var files = 0
            for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
                let url = root.appendingPathComponent(path)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                #expect(Self.mode(url) == (isDirectory.boolValue ? 0o700 : 0o600), "\(path) on \(mac.name)")
                files += isDirectory.boolValue ? 0 : 1
            }
            #expect(files > 0)
        }
        let aID = try #require(try await a.read().hostID)
        let logs = try #require(a.server.fleetStoreDirectory).appendingPathComponent("ops-\(aID.uuidString).ndjson")
        let text = try String(contentsOf: logs, encoding: .utf8)
        #expect(Self.mode(logs) == 0o600 && text.contains("fake-refresh-1"))
    }

    // MARK: Who receives them

    @Test func aRemovedMacReceivesNoFurtherSignIns() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini"), c = try await Mac("Mac Studio")
        defer { a.stop(); b.stop(); c.stop() }
        try await Self.enabled(a, b, c)
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        try await a.pair(with: c)
        for (one, other) in [(a, c), (c, a), (b, c), (c, b)] { try await one.waitForLink(to: other) }

        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try await eventually("every Mac to hold generation 1") { Self.refresh(b) == "fake-refresh-1" && Self.refresh(c) == "fake-refresh-1" }

        // The Mac mini leaves the fleet, from the MacBook; the others drop it.
        let bID = try #require(try await b.read().hostID)
        _ = try await a.local.fleetAction(.remove(hostID: bID))
        // (Whether the Mac mini hears of it is the pairing's business: it may not, if the link is gone first. Either
        // way the others refuse its token, so it holds no link that works.)
        try await eventually("the others to drop the Mac mini and the Mac mini to hold no working link") {
            let left = try await b.read().peers
            let seenByA = try await a.read().peers.map(\.name), seenByC = try await c.read().peers.map(\.name)
            return left.allSatisfy { $0.link != .connected } && seenByA == ["Mac Studio"] && seenByC == ["MacBook Pro"]
        }

        // A refresh and a new sign-in after that reach the Mac Studio, and not the Mac mini.
        try Self.piWrites(Self.acme, Self.oauth(2), in: Self.auth(a))
        try Self.piWrites(Self.widgets, ["type": "api_key", "key": "fake-key"], in: Self.auth(a))
        try Self.piWrites(Self.notionKey, Self.server(1), in: Self.mcpAuth(a))
        try await eventually("the Mac Studio to hold the new sign-ins") {
            Self.refresh(c) == "fake-refresh-2" && Self.contents(Self.auth(c))[Self.widgets] != nil && Self.mcpRefresh(c) == "fake-mcp-refresh-1"
        }
        #expect(Self.refresh(b) == "fake-refresh-1", "the Mac mini still has the one it had")
        #expect(Self.contents(Self.auth(b))[Self.widgets] == nil && Self.mcpRefresh(b) == nil)
        #expect(b.server.fleetSyncWinner("credential:\(Self.widgets)") == nil, "its store never heard of them")
        #expect(b.server.fleetSyncWinner("mcpAuth:\(Self.notionKey)") == nil)
        // And its fence has no one to ask: it starts pi at once.
        let took = await ContinuousClock().measure { await b.server.fleetCredentialFence() }
        #expect(took < .milliseconds(250))
    }

    @Test func aDeviceOrASharedTokenClientNeverReceivesOrSendsSignIns() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.piWrites(Self.acme, Self.oauth(1), in: Self.auth(a))
        try await eventually("Mac mini to hold the sign-in") { Self.refresh(b) == "fake-refresh-1" }

        // A phone with a token of its own, connected to the MacBook while a refresh happens.
        let token = FleetProtocol.makeToken()
        let intro = FleetDeviceIntroduction(deviceID: UUID(), name: "iPhone", kind: .iphone, tokenHash: FleetProtocol.hash(token))
        let code = try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code
        _ = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: a.port, code: code, device: intro)
        let phone = RemoteHostClient()
        let heard = Locked<[String]>([])
        phone.onStateChanged = { state in heard.withValue { $0.append(String(describing: state)) } }
        phone.onSettingsChanged = { page in heard.withValue { $0.append(String(describing: page)) } }
        defer { phone.disconnect() }
        _ = try await phone.connect(host: "127.0.0.1", port: a.port, token: token, clientName: "iPhone")
        #expect(!phone.capabilities.contains(RemoteProtocol.fleetSyncCapability), "a device is not offered sync")

        try Self.piWrites(Self.acme, Self.oauth(2), in: Self.auth(a))
        try await eventually("Mac mini to hold the refresh") { Self.refresh(b) == "fake-refresh-2" }

        // The shared token is not a member either, nor is this Mac's own app: sync is a member's.
        let shared = RemoteHostClient()
        defer { shared.disconnect() }
        _ = try await shared.connect(host: "127.0.0.1", port: a.port, token: a.sharedToken, clientName: "Old client")
        let stolen = FleetOp(mac: UUID(), seq: 1, hlc: FleetHLC(wallMs: 9_999_999_999_999), unit: "credential:\(Self.acme)",
                             change: .value(#"{"type":"oauth","access":"fake-evil","refresh":"fake-evil","expires":1}"#))
        for (name, client) in [("a device", phone), ("the shared token", shared), ("this Mac's app", a.local)] {
            let attempts: [FleetSyncRequest] = [.hello(vector: FleetVersionVector()), .hello(vector: FleetVersionVector(), fresh: true),
                                                .ops([stolen]), .op(stolen),
                                                .blob(hash: FleetSyncProtocol.hash(Data("x".utf8)), offset: 0)]
            for request in attempts {
                do { _ = try await client.fleetSync(request); Issue.record("\(name) used the fleet's sync") }
                catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden, "\(name)") }
            }
        }
        #expect(Self.refresh(a) == "fake-refresh-2" && Self.refresh(b) == "fake-refresh-2", "nothing it sent was taken")
        #expect(a.server.fleetSyncWinner("credential:\(Self.acme)")?.mac != stolen.mac)

        // Nothing the host pushed to the phone held a token.
        let seen = heard.current.joined()
        #expect(!seen.contains("fake-refresh") && !seen.contains("fake-access"))
        #expect(!FleetAccess.device.takesPartInFleet && !FleetAccess.shared.takesPartInFleet && FleetAccess.member.takesPartInFleet)
    }
}

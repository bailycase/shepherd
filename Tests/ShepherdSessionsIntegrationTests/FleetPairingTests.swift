import CryptoKit
import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Fleet's first slice end to end between real scratch hosts: pairing by code, the host's link to
/// each peer, and removal. Each `Mac` is a `SessionServer` with
/// its remote listener (what another Mac reaches), its local socket (what its own app uses) and
/// a fleet, on a private scratch folder; nothing advertises on the network.
@Suite("Fleet pairing", .integrationTimeLimit)
struct FleetPairingTests {
    /// A scratch host that takes part in a fleet.
    final class Mac: @unchecked Sendable {
        let host: ScratchServer
        let port: UInt16
        let name: String
        let local: RemoteHostClient
        let sharedToken: String
        var server: SessionServer { host.server }
        var peersFile: URL { host.dir.appendingPathComponent("fleet/peers.json") }

        /// `port` 0 picks one that stays free for a restart; a restarted Mac asks for the one it had, as a real host's is fixed.
        /// `configure` sets the host up before its fleet starts (an iCloud store to stand in for CloudKit, say).
        init(_ name: String, dir: URL? = nil, port: UInt16 = 0, configure: (SessionServer) -> Void = { _ in }) async throws {
            self.name = name
            let host = try ScratchServer(dir: dir)
            let server = host.server
            server.configureFleet(name: name, advertises: false)
            configure(server)
            let tokenURL = host.dir.appendingPathComponent("remote-token")
            let socket = host.dir.appendingPathComponent("h.sock").path
            let port = try await RestartablePort.listen(port) { try server.startRemoteListener(port: $0, tokenURL: tokenURL) }
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try server.startLocalListener(path: socket, tokenURL: tokenURL)
            server.startFleetAndWait()
            let local = RemoteHostClient(localSocket: socket)
            _ = try await local.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            (self.host, self.port, self.sharedToken, self.local) = (host, port, token, local)
        }

        func stop(keepFiles: Bool = false) {
            local.disconnect()
            host.stop(keepFiles: keepFiles)
        }

        func read() async throws -> FleetSnapshot { try await local.fleetRead().snapshot }

        /// The code this Mac's Join screen shows.
        func startJoin() async throws -> String {
            try #require(try await local.fleetAction(.startJoin).join).code
        }

        /// Enters `code` shown by `other`.
        @discardableResult
        func pair(with other: Mac, code: String) async throws -> FleetPeerStatus {
            try #require(try await local.fleetAction(.pair(host: "127.0.0.1", port: other.port, code: code)).paired)
        }

        func peers() async throws -> [FleetPeerStatus] { try await read().peers }

        func waitForLink(to other: Mac) async throws {
            try await eventually("\(name) to hold a link to \(other.name)") {
                try await self.peers().contains { $0.name == other.name && $0.link == .connected }
            }
        }

        /// What `peers.json` holds for the peer called `name`.
        func record(of name: String) throws -> [String: Any] {
            let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: peersFile)) as? [String: Any])
            let peers = try #require(file["peers"] as? [[String: Any]])
            return try #require(peers.first { $0["name"] as? String == name })
        }
    }

    // MARK: Pairing

    @Test func twoHostsPairByCodeAndBothHoldTheLink() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }

        let code = try await b.startJoin()
        #expect(code.count == FleetProtocol.codeLength && code.allSatisfy(\.isNumber))
        let paired = try await a.pair(with: b, code: code)
        #expect(paired.name == "Mac mini")

        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        let aSees = try await a.peers(), bSees = try await b.peers()
        #expect(aSees.map(\.name) == ["Mac mini"] && bSees.map(\.name) == ["MacBook Pro"])
        #expect(try await b.read().join == nil, "the code is spent")

        // Each side presents the token it made, and keeps only the other's hash.
        let atA = try a.record(of: "Mac mini"), atB = try b.record(of: "MacBook Pro")
        let aToken = try #require(atA["myToken"] as? String), bToken = try #require(atB["myToken"] as? String)
        #expect(aToken != bToken)
        #expect(atA["peerTokenHash"] as? String == FleetProtocol.hash(bToken))
        #expect(atB["peerTokenHash"] as? String == FleetProtocol.hash(aToken))
        let files = [a.peersFile, b.peersFile, a.host.dir.appendingPathComponent("fleet/identity.json")]
        for file in files {
            var mode = stat()
            #expect(stat(file.path, &mode) == 0 && mode.st_mode & 0o777 == 0o600, "\(file.lastPathComponent) is private")
        }
    }

    /// Each host keeps its identity and its pairings through a restart, and the link comes back.
    @Test(arguments: [true, false])
    func thePairingSurvivesARestartOfEitherHost(restartingTheJoiner: Bool) async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        var restarted: Mac?
        defer { a.stop(); b.stop(); restarted?.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        let idBefore = try #require(try await (restartingTheJoiner ? b : a).read().hostID)

        let (gone, staying) = restartingTheJoiner ? (b, a) : (a, b)
        let (dir, port) = (gone.host.dir, gone.port)
        gone.stop(keepFiles: true)
        try await eventually("the link to \(gone.name) to drop") {
            try await staying.peers().first?.link != .connected
        }
        let back = try await Mac(gone.name, dir: dir, port: port)
        restarted = back
        #expect(try await back.read().hostID == idBefore, "a host keeps who it is")
        try await staying.waitForLink(to: back)
        try await back.waitForLink(to: staying)
    }

    @Test func aWrongCodeIsRefusedAndFiveInvalidateTheCode() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        let wrong = code == "000000" ? "111111" : "000000"

        var codes: [String] = []
        for _ in 0..<FleetProtocol.maxCodeAttempts {
            do { try await a.pair(with: b, code: wrong); Issue.record("a wrong code paired") }
            catch RemoteHostClientError.rejected(let code, _) { codes.append(code) }
        }
        #expect(codes == Array(repeating: FleetProtocol.Code.badCode, count: 4) + [FleetProtocol.Code.lockedOut])
        #expect(try await b.read().join == nil, "five wrong tries close the window")

        // The right code is no good now: the Join screen has to open again for a new one.
        do { try await a.pair(with: b, code: code); Issue.record("a locked out code paired") }
        catch RemoteHostClientError.rejected(let refused, _) { #expect(refused == FleetProtocol.Code.notJoining) }
        let (aPeers, bPeers) = (try await a.peers(), try await b.peers())
        #expect(aPeers.isEmpty && bPeers.isEmpty)

        // A new window, a new code.
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
    }

    @Test func aMacThatIsNotJoiningTakesNoCode() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        do { try await a.pair(with: b, code: "482913"); Issue.record("paired with no window open") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.notJoining) }
        _ = try await b.startJoin()
        _ = try await b.local.fleetAction(.stopJoin)
        do { try await a.pair(with: b, code: "482913"); Issue.record("paired after the window closed") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.notJoining) }
    }

    // MARK: Tokens

    @Test func aPeersTokenIsRefusedOnceItIsRemoved() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        let bToken = try #require(try b.record(of: "MacBook Pro")["myToken"] as? String)
        let bHostID = try #require(try await b.read().hostID)

        // A's token for B opens a connection while B is in the fleet…
        let before = RemoteHostClient()
        _ = try await before.connect(host: "127.0.0.1", port: a.port, token: bToken, clientName: "Mac mini", capabilities: [],
                                     expectingHostID: nil, fetchesState: false)
        #expect(before.hostID != nil)
        before.disconnect()

        // …and not after A removes it.
        let aSees = try await a.peers()
        let removed = try #require(aSees.first).hostID
        let after = try await a.local.fleetAction(.remove(hostID: removed))
        #expect(after.snapshot.peers.isEmpty)
        let late = RemoteHostClient()
        defer { late.disconnect() }
        do {
            _ = try await late.connect(host: "127.0.0.1", port: a.port, token: bToken, clientName: "Mac mini", capabilities: [],
                                       fetchesState: false)
            Issue.record("a removed Mac's token was accepted")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == RemoteProtocol.unauthorizedCode)
        }
        // The Mac that was removed is told, and drops what it paired.
        try await eventually("the removed Mac to leave the fleet") { try await b.peers().isEmpty }
        _ = bHostID
        let tombstone = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: a.peersFile)) as? [String: Any])
        let record = try #require((tombstone["peers"] as? [[String: Any]])?.first)
        #expect(record["revoked"] as? Bool == true && record["myToken"] == nil && record["peerTokenHash"] == nil, "no token is kept")
    }

    /// The Mac at a saved address answers as another host: nothing of the pairing is sent to it.
    @Test func aHostThatAnswersWithAnotherIDNeverReceivesAToken() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await eventually("the link to drop") { try await a.peers().first?.link != .connected }

        // Another machine takes the address. It says who it is, and records everything it is sent.
        let heard = Locked<[String]>([])
        let impostor = try LoopbackServer(port: port) { fd in
            while let line = Self.readLine(fd) {
                heard.withValue { $0.append(String(decoding: line, as: UTF8.self)) }
                guard let request = try? NDJSON.decode(RemoteRequest.self, from: line), case .fleetIdentify(let id) = request else { return }
                let reply = RemoteReply.fleetIdentity(id: id, hostID: UUID(), name: "Mac mini", build: nil, fleetEnabled: true)
                LoopbackServer.writeAll(fd, (try? NDJSON.encode(reply)) ?? Data())
            }
        }
        defer { impostor.stop() }

        let token = try #require(try a.record(of: "Mac mini")["myToken"] as? String)
        try await eventually("A to ask the impostor who it is") { heard.current.contains { $0.contains("fleetIdentify") } }
        // Give the link every chance to misbehave: it retries, and each try only asks.
        try await eventually("a second try") { impostor.connections.current >= 2 }
        #expect(heard.current.allSatisfy { !$0.contains("\"hello\"") && !$0.contains(token) }, "a hello or the token reached the impostor")
        #expect(try await a.peers().first?.link != .connected)
    }

    @Test func aMacCannotPairWithItself() async throws {
        let a = try await Mac("MacBook Pro")
        defer { a.stop() }
        let code = try await a.startJoin()
        do { try await a.pair(with: a, code: code); Issue.record("a Mac paired with itself") }
        catch RemoteHostClientError.rejected(let refused, _) { #expect(refused == FleetProtocol.Code.invalid) }
        #expect(try await a.peers().isEmpty)
    }

    // MARK: Joining a fleet of three

    /// A Mac that pairs with one member is introduced to every other: each holds a link to each.
    @Test func aNewMacIsIntroducedToTheWholeFleetAndRemovedFromAllOfIt() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini"), c = try await Mac("Mac Studio")
        defer { a.stop(); b.stop(); c.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)

        // C joins through A, which brokers its introduction to B.
        try await a.pair(with: c, code: try await c.startJoin())
        for (one, other) in [(a, c), (c, a), (b, c), (c, b)] { try await one.waitForLink(to: other) }
        #expect(Set(try await c.peers().map(\.name)) == ["MacBook Pro", "Mac mini"])
        #expect(Set(try await b.peers().map(\.name)) == ["MacBook Pro", "Mac Studio"])

        // B removes C: every Mac drops it, wherever it was removed from.
        let cID = try #require(try await c.read().hostID)
        _ = try await b.local.fleetAction(.remove(hostID: cID))
        try await eventually("every Mac to drop the removed one") {
            let seen = try await [a.peers(), b.peers()].map { $0.map(\.name) }
            let left = try await c.peers()
            return seen == [["Mac mini"], ["MacBook Pro"]] && left.isEmpty
        }
    }

    // MARK: Only the app, only the local socket

    @Test func onlyThisMacsOwnAppReadsOrChangesItsFleet() async throws {
        let a = try await Mac("MacBook Pro")
        defer { a.stop() }
        let remote = try await RemoteHostClient.connected(to: a)
        defer { remote.disconnect() }
        do { _ = try await remote.fleetAction(.startJoin); Issue.record("a remote client used the app's fleet requests") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
        // It reads what a phone does (`fleet.view.v1`): the Macs and their load, not how they are reached.
        let view = try await remote.fleetRead().snapshot
        let hostID = try await a.read().hostID
        #expect(view.hostID == hostID && view.addresses.isEmpty && view.port == nil && view.devices == nil)
        // Nor does one pair, remove or introduce with the shared token.
        do { _ = try await remote.fleetRevoke(hostID: UUID(), at: 1); Issue.record("a shared token removed a Mac") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
    }

    @Test func fleetPairingTakesNoCodeOnceHelloWasSaid() async throws {
        let a = try await Mac("MacBook Pro")
        defer { a.stop() }
        let raw = try RawRemote(port: a.port)
        try await raw.hello(token: a.sharedToken)
        try raw.send(.fleetPair(id: 5, code: "482913", from: FleetIntroduction(hostID: UUID(), name: "x", myTokenHash: FleetProtocol.hash("t"), port: 7434)))
        guard case .error(5, let code, _) = try await raw.next() else { Issue.record("expected a refusal"); return }
        #expect(code == FleetProtocol.Code.forbidden)
    }

    /// The pre-hello fleet requests are rate limited per connection.
    @Test func unauthenticatedFleetRequestsAreLimited() async throws {
        let a = try await Mac("MacBook Pro")
        defer { a.stop() }
        let raw = try RawRemote(port: a.port, receiveBufferBytes: nil)
        var refused = false
        for id in 1...(FleetService.unauthenticatedRequestLimit + 2) {
            try raw.send(.fleetIdentify(id: id))
            let reply = try await raw.next()
            if case .error(_, FleetProtocol.Code.busy, _) = reply { refused = true; break }
        }
        #expect(refused)
        #expect(try await raw.disconnected())
    }

    // MARK: Helpers

    static func readLine(_ fd: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
    }
}

extension RemoteHostClient {
    /// A client of `mac`'s listener with the shared token, as a phone or an older Mac is.
    static func connected(to mac: FleetPairingTests.Mac) async throws -> RemoteHostClient {
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: mac.port, token: mac.sharedToken, clientName: "iPhone")
        return client
    }
}

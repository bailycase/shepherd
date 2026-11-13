import Darwin
import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Pairing with a Mac named by a pairing link or found over SSH, on real scratch hosts with no Bonjour and no iCloud: the answering Mac
/// must be the one the link names, the code is still the only proof, and a link that has expired pairs nothing.
@Suite("Fleet pairing link and SSH", .integrationTimeLimit)
struct FleetPairLinkTests {
    typealias Mac = FleetPairingTests.Mac

    /// A host that says its listener is at `127.0.0.1` (and, before it, `extra`), with iCloud unavailable.
    static func mac(_ name: String, extra: [FleetRoute] = [], joinLifetime: TimeInterval? = nil) async throws -> Mac {
        try await Mac(name) {
            $0.configureFleetRendezvous(store: UnavailableFleetRendezvousStore(),
                                        routes: { port in extra + [FleetRoute(host: "127.0.0.1", port: port, kind: .lan, learned: false)] },
                                        joinLifetime: joinLifetime, lookupInterval: 0)
        }
    }

    /// The link `mac`'s Join screen shares for its open code, as the app makes it.
    static func link(of mac: Mac, code: String, purpose: FleetPairingLink.Purpose = .join, hostID: UUID? = nil, expiresAt: Double? = nil) async throws -> FleetPairingLink {
        let snapshot = try await mac.read()
        return FleetPairingLink(purpose: purpose, hostID: try hostID ?? #require(snapshot.hostID), name: snapshot.name, port: try #require(snapshot.port),
                                routes: snapshot.routes, code: code, expiresAt: try expiresAt ?? #require(snapshot.join).expiresAt)
    }

    /// What the app asks its host once a link is read: opened from its URL, as a pasted one is.
    static func pair(_ mac: Mac, via link: FleetPairingLink) async throws -> FleetPeerStatus {
        guard case .link(let read) = FleetPairingLink.read(link.url(scheme: "shepherd"), scheme: "shepherd") else { throw Refused.notALink }
        return try #require(try await mac.local.fleetAction(.pairAt(hostID: read.hostID, port: read.port, routes: read.routes, code: read.code,
                                                                   expiresAt: read.expiresAt)).paired)
    }

    enum Refused: Error { case notALink }

    static func refusal(_ body: () async throws -> Void) async -> (code: String, message: String)? {
        do { try await body() } catch RemoteHostClientError.rejected(let code, let message) { return (code, message) } catch { return nil }
        return nil
    }

    // MARK: A link

    @Test func aLinkPairsTwoHostsWithNoBonjourAndTheCodeIsSpent() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        let link = try await Self.link(of: b, code: code)
        #expect(link.routes == [FleetReportedRoute(host: "127.0.0.1", kind: .lan)] && link.port == b.port, "the link says where the Mac says it is")

        let paired = try await Self.pair(a, via: link)
        #expect(paired.name == "Mac mini")
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        #expect(try await b.read().join == nil, "the code is used")

        // The same link again: its code is spent, so it pairs nothing.
        let again = await Self.refusal { _ = try await Self.pair(a, via: link) }
        #expect(again != nil)
    }

    @Test func aLinkWhoseMacAnswersWithAnotherIDPairsNothingAndSpendsNoTry() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        // An address another Mac now holds: the link names a Mac that isn't the one at its routes.
        let stale = try await Self.link(of: b, code: code, hostID: UUID())
        let refused = await Self.refusal { _ = try await Self.pair(a, via: stale) }
        #expect(refused != nil)
        let (aPeers, bPeers) = (try await a.peers(), try await b.peers())
        #expect(aPeers.isEmpty && bPeers.isEmpty)
        #expect(try await b.read().join?.attemptsLeft == FleetProtocol.maxCodeAttempts, "the code never reached it")
    }

    @Test func aLinkPastItsExpiryIsRefusedWithoutAConnection() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        let expired = try await Self.link(of: b, code: code, expiresAt: Date().timeIntervalSince1970 * 1000 - 1)
        let refused = await Self.refusal { _ = try await Self.pair(a, via: expired) }
        #expect(refused?.code == FleetProtocol.Code.linkExpired)
        let (tries, peers) = (try await b.read().join?.attemptsLeft, try await a.peers())
        #expect(tries == FleetProtocol.maxCodeAttempts && peers.isEmpty)
    }

    @Test func aLinkWhoseCodeHasExpiredOnTheOtherMacIsRefusedByIt() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini", joinLifetime: 0.3)
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        // A link that still says it is good (a stale clock, a stale copy): the Mac that showed the code is the judge.
        let link = try await Self.link(of: b, code: code, expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        try await eventually("the code's window to close") { try await b.read().join == nil }
        let refused = await Self.refusal { _ = try await Self.pair(a, via: link) }
        #expect(refused?.code == FleetProtocol.Code.notJoining || refused?.code == FleetProtocol.Code.codeExpired, "\(String(describing: refused))")
        let (aPeers, bPeers) = (try await a.peers(), try await b.peers())
        #expect(aPeers.isEmpty && bPeers.isEmpty)
    }

    @Test func theCodeInALinkIsCheckedLikeATypedOne() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        let wrong = code == "000000" ? "111111" : "000000"
        let refused = await Self.refusal { _ = try await Self.pair(a, via: try await Self.link(of: b, code: wrong)) }
        #expect(refused?.code == FleetProtocol.Code.badCode)
        let (tries, peers) = (try await b.read().join?.attemptsLeft, try await a.peers())
        #expect(tries == FleetProtocol.maxCodeAttempts - 1 && peers.isEmpty)
        // The right code, still open, pairs.
        _ = try await Self.pair(a, via: try await Self.link(of: b, code: code))
        try await a.waitForLink(to: b)
    }

    @Test func routesAreTriedInOrderAndAnUnreachableOneIsSkipped() async throws {
        let a = try await Self.mac("MacBook Pro")
        // The first route is a name that resolves nowhere; the second is the Mac.
        let b = try await Self.mac("Mac mini", extra: [FleetRoute(host: "no-such-mac.invalid", port: 1, kind: .hostname, learned: false)])
        defer { a.stop(); b.stop() }
        let link = try await Self.link(of: b, code: try await b.startJoin())
        #expect(link.routes.map(\.host) == ["no-such-mac.invalid", "127.0.0.1"])
        _ = try await Self.pair(a, via: link)
        try await a.waitForLink(to: b)
    }

    @Test func aLinkThatNoRouteAnswersSaysSo() async throws {
        let a = try await Self.mac("MacBook Pro")
        defer { a.stop() }
        let nowhere = FleetPairingLink(hostID: UUID(), name: "Mac mini", port: 1, routes: [FleetReportedRoute(host: "no-such-mac.invalid", kind: .hostname)],
                                       code: "482913", expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        let refused = await Self.refusal { _ = try await Self.pair(a, via: nowhere) }
        #expect(refused?.code == FleetProtocol.Code.unreachable)
        #expect(try await a.peers().isEmpty)
    }

    @Test func aLinkThatNamesThisMacOrNothingIsRefused() async throws {
        let a = try await Self.mac("MacBook Pro")
        defer { a.stop() }
        let own = try #require(try await a.read().hostID)
        let me = FleetPairingLink(hostID: own, name: "MacBook Pro", port: a.port, routes: [FleetReportedRoute(host: "127.0.0.1", kind: .lan)], code: "482913",
                                  expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        #expect(await Self.refusal { _ = try await Self.pair(a, via: me) }?.code == FleetProtocol.Code.invalid)
        let nowhere = await Self.refusal { _ = try await a.local.fleetAction(.pairAt(hostID: UUID(), port: 7434, routes: [], code: "482913", expiresAt: nil)) }
        #expect(nowhere?.code == FleetProtocol.Code.invalid, "a link that says where nothing is")
        let badHost = await Self.refusal {
            _ = try await a.local.fleetAction(.pairAt(hostID: UUID(), port: 7434, routes: [FleetReportedRoute(host: "http://evil", kind: .lan)], code: "482913", expiresAt: nil))
        }
        #expect(badHost?.code == FleetProtocol.Code.invalid)
    }

    @Test func aHostSaysItsOwnRoutesWithTheirKinds() async throws {
        let named = [FleetRoute(host: "mac-mini.local", port: 1, kind: .hostname, learned: false), FleetRoute(host: "100.101.102.103", port: 1, kind: .tailscale, learned: false)]
        let b = try await Self.mac("Mac mini", extra: named)
        defer { b.stop() }
        let snapshot = try await b.read()
        #expect(snapshot.routes == [FleetReportedRoute(host: "mac-mini.local", kind: .hostname), FleetReportedRoute(host: "100.101.102.103", kind: .tailscale),
                                    FleetReportedRoute(host: "127.0.0.1", kind: .lan)])
        #expect(snapshot.clientView.routes.isEmpty)
    }

    // MARK: A device link

    @Test func aDevicesLinkNamesTheMacAndTheDeviceCodeChecksIt() async throws {
        let b = try await Self.mac("Mac mini")
        defer { b.stop() }
        let shown = try #require(try await b.local.fleetAction(.startDeviceCode).deviceCode)
        let snapshot = try await b.read()
        let link = FleetPairingLink(purpose: .device, hostID: try #require(snapshot.hostID), name: snapshot.name, port: try #require(snapshot.port), routes: snapshot.routes,
                                    code: shown.code, expiresAt: shown.expiresAt)
        let device = FleetDeviceIntroduction(deviceID: UUID(), name: "iPhone", kind: .iphone, tokenHash: FleetProtocol.hash(FleetProtocol.makeToken()))

        // Another Mac at the address: refused before the code is sent.
        let other = await Self.refusal { _ = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: link.port, code: link.code, device: device, expecting: UUID()) }
        #expect(other?.code == FleetProtocol.Code.wrongHost)
        let paired = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: link.port, code: link.code, device: device, expecting: link.hostID)
        #expect(paired.result.name == "Mac mini" && paired.identity.hostID == link.hostID)
    }

    // MARK: A Mac from before links

    /// The other Mac is told what it always was: the link changes nothing on the wire, so a Mac without `fleet.pairlink.v1` pairs as before.
    @Test func aMacFromBeforeLinksIsPairedWithByItsLinkAsAlways() async throws {
        let (oldID, oldToken) = (UUID(), FleetProtocol.makeToken())
        let heard = Locked<[String]>([])
        let presented = Locked<String?>(nil)
        let offered = RemoteProtocol.capabilities.filter { ![RemoteProtocol.fleetLinkCapability, RemoteProtocol.fleetPairLinkCapability, RemoteProtocol.fleetRendezvousCapability].contains($0) }
        let oldHost = try LoopbackServer { fd in
            func reply(_ reply: RemoteReply) { LoopbackServer.writeAll(fd, (try? NDJSON.encode(reply)) ?? Data()) }
            while let line = FleetPairingTests.readLine(fd) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String,
                      let request = try? NDJSON.decode(RemoteRequest.self, from: line) else { continue }
                heard.withValue { $0.append(type) }
                switch request {
                case .fleetIdentify(let id): reply(.fleetIdentity(id: id, hostID: oldID, name: "Mac mini", build: "old", fleetEnabled: true))
                case .fleetPair(let id, let code, let from):
                    guard code == "482913" else { return reply(.error(id: id, code: FleetProtocol.Code.badCode, message: "That code isn't right.")) }
                    presented.withValue { $0 = from.myTokenHash }
                    reply(.fleetPaired(id: id, hostID: oldID, name: "Mac mini", myTokenHash: FleetProtocol.hash(oldToken)))
                case .hello(let id, let token, _, _, _):
                    guard FleetProtocol.hash(token) == presented.current else { return reply(.error(id: id, code: RemoteProtocol.unauthorizedCode, message: "bad token")) }
                    reply(.helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: offered, hostBuild: "old", hostID: oldID))
                case .fleetPressure(let id, _), .fleetReadiness(let id, _): reply(.ok(id: id))
                default: reply(.error(id: 0, code: "unsupported", message: "The host does not take this request."))
                }
            }
        }
        defer { oldHost.stop() }
        let a = try await Self.mac("MacBook Pro")
        defer { a.stop() }
        let link = FleetPairingLink(hostID: oldID, name: "Mac mini", port: oldHost.port, routes: [FleetReportedRoute(host: "127.0.0.1", kind: .lan)], code: "482913",
                                    expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        let paired = try await Self.pair(a, via: link)
        #expect(paired.name == "Mac mini")
        #expect(Array(heard.current.prefix(2)) == ["fleetIdentify", "fleetPair"], "who answers is asked first, then the code: nothing the old Mac doesn't know")
        // And a link naming another id than the old Mac's pairs nothing: it is never sent the code.
        let before = heard.current.filter { $0 == "fleetPair" }.count
        let wrong = FleetPairingLink(hostID: UUID(), name: "Mac mini", port: oldHost.port, routes: [FleetReportedRoute(host: "127.0.0.1", kind: .lan)], code: "482913",
                                     expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        #expect(await Self.refusal { _ = try await Self.pair(a, via: wrong) } != nil)
        #expect(heard.current.filter { $0 == "fleetPair" }.count == before)
    }

    // MARK: SSH

    /// A folder with a fake `ssh` on its `PATH`: it records its arguments and runs `body`.
    final class FakeSSH {
        let dir: URL
        var arguments: URL { dir.appendingPathComponent("arguments") }

        init(_ body: String) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("ssh")
            try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(arguments.path)'\n\(body)\n".utf8).write(to: script)
            chmod(script.path, 0o755)
        }

        deinit { try? FileManager.default.removeItem(at: dir) }

        var finder: FleetSSHFinder {
            FleetSSHFinder(appName: "Shepherd Nightly", environment: ["PATH": "\(dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: 15, connectTimeout: 3)
        }

        var recorded: [String] { ((try? String(contentsOf: arguments, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    }

    @Test func aFoundMacIsAskedOverSSHAndNothingIsPairedUntilItsCodeIsEntered() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        // What `Shepherd --fleet-where` prints on the Mac, read from its real host over its local socket.
        let socket = b.host.dir.appendingPathComponent("h.sock").path
        let outcome = await FleetWhereCommand.read(socket: socket, token: b.sharedToken, app: "Shepherd Nightly")
        guard case .found(let answer) = outcome else { Issue.record("the host didn't say where it is: \(outcome)"); return }
        #expect(answer.name == "Mac mini" && answer.port == b.port && answer.routes == [FleetReportedRoute(host: "127.0.0.1", kind: .lan)] && answer.app == "Shepherd Nightly")
        let canned = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-where-\(UUID().uuidString.prefix(8)).json")
        try Data((answer.line() + "\n").utf8).write(to: canned)
        defer { try? FileManager.default.removeItem(at: canned) }

        let ssh = try FakeSSH("cat '\(canned.path)'")
        let found = try await ssh.finder.find("me@mini.example.internal")
        #expect(found == answer)
        // ssh ran as the user's own: BatchMode, a bounded connect, `--` before the target, and the read-only command.
        let args = ssh.recorded
        #expect(args.contains("BatchMode=yes") && args.contains { $0.hasPrefix("ConnectTimeout=") } && args.contains("-T"))
        let dashes = try #require(args.firstIndex(of: "--"))
        #expect(args[dashes + 1] == "me@mini.example.internal" && args.last?.hasPrefix("/bin/sh -c '") == true && args.last?.contains("fleet-where") == true)

        // Finding paired nothing and spent nothing; the code does that, over a direct connection to the Mac it found.
        let code = try await b.startJoin()
        let (aPeers, bPeers) = (try await a.peers(), try await b.peers())
        #expect(aPeers.isEmpty && bPeers.isEmpty && b.record("fleet").isEmpty)
        let paired = try #require(try await a.local.fleetAction(.pairAt(hostID: found.hostID, port: found.port, routes: found.routes, code: code, expiresAt: nil)).paired)
        #expect(paired.name == "Mac mini")
        try await a.waitForLink(to: b)
    }

    @Test func aMacFoundOverSSHThatIsNotTheOneAtItsAddressIsNotPaired() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        // ssh said Mac mini is this id, but the Mac at that address is another.
        let refused = await Self.refusal {
            _ = try await a.local.fleetAction(.pairAt(hostID: UUID(), port: b.port, routes: [FleetReportedRoute(host: "127.0.0.1", kind: .lan)], code: code, expiresAt: nil))
        }
        let tries = try await b.read().join?.attemptsLeft
        #expect(refused != nil && tries == FleetProtocol.maxCodeAttempts)
    }

    @Test func sshThatIsRefusedFailsWithAWordForIt() async throws {
        let ssh = try FakeSSH("echo 'me@mini: Permission denied (publickey).' >&2; exit 255")
        await #expect(throws: FleetSSHFinder.Failure.self) { try await ssh.finder.find("me@mini") }
        do { _ = try await ssh.finder.find("me@mini") } catch let FleetSSHFinder.Failure.connection(message) {
            #expect(message.contains("Shepherd never asks for a password"))
        }
    }

    @Test func aMacWithoutShepherdOrWithAnOldOneIsSaidSo() async throws {
        let none = try FakeSSH("echo shepherd-not-installed >&2; exit 127")
        await #expect(throws: FleetSSHFinder.Failure.notInstalled) { try await none.finder.find("mini") }
        let old = try FakeSSH("echo 'shepherd: unknown arguments: fleet-where' >&2; exit 1")
        await #expect(throws: FleetSSHFinder.Failure.notInstalled) { try await old.finder.find("mini") }
        let garbage = try FakeSSH("echo 'Welcome to a router'")
        await #expect(throws: FleetSSHFinder.Failure.unreadable) { try await garbage.finder.find("mini") }
        let down = try FakeSSH("echo 'shepherd: Shepherd isn'\\''t running' >&2; exit 3")
        await #expect(throws: FleetSSHFinder.Failure.notRunning) { try await down.finder.find("mini") }
    }

    @Test func aMacThatNeverAnswersIsGivenUpOnAtTheLimitAndSSHIsStopped() async throws {
        let pid = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-pid-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: pid) }
        let ssh = try FakeSSH("echo $$ > '\(pid.path)'; exec sleep 60")
        var finder = ssh.finder
        finder.timeout = 1
        let started = ContinuousClock.now
        await #expect(throws: FleetSSHFinder.Failure.timedOut) { try await finder.find("me@mini") }
        #expect(ContinuousClock.now - started < .seconds(10), "bounded by the limit, not by ssh")
        let running = try #require(Int32(String(contentsOf: pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await eventually("the hung ssh to be killed") { kill(running, 0) != 0 }
    }

    @Test func aTargetThatIsAnOptionIsNeverGivenToSSH() async throws {
        let ssh = try FakeSSH("exit 0")
        for bad in ["-oProxyCommand=touch /tmp/x", "-J evil", "me@mini extra"] {
            await #expect(throws: FleetSSHFinder.Failure.badTarget) { try await ssh.finder.find(bad) }
        }
        #expect(ssh.recorded.isEmpty, "ssh never ran")
    }

    // MARK: Where a host says it listens

    @Test func aHostThatIsNotRunningOrNotListeningHasNothingToSay() async throws {
        let none = await FleetWhereCommand.read(socket: "/tmp/no-such-\(UUID().uuidString.prefix(6)).sock", token: "x")
        #expect(none == .notRunning && none.status == FleetWhereCommand.notRunningStatus)
        let alone = try await Self.mac("Mac mini")
        defer { alone.stop() }
        let read = await FleetWhereCommand.read(socket: alone.host.dir.appendingPathComponent("h.sock").path, token: alone.sharedToken)
        guard case .found(let found) = read else { Issue.record("a Mac with no other Mac still says where it listens: \(read)"); return }
        #expect(found.port == alone.port, "an iPhone is added to a Mac that is in no fleet, too")
    }
}

private extension FleetPairingTests.Mac {
    /// Files the Mac keeps for its pairings: none until a code is entered.
    func record(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: host.dir.appendingPathComponent(folder).path))?.filter { $0 == "peers.json" } ?? []
    }
}

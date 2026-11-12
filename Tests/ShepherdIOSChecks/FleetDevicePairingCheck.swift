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
        let mini = try FakeMac(name: "Mac mini", fleet: fleet), studio = try FakeMac(name: "Mac Studio", fleet: fleet)
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
        check(saved.count == 2 && saved.allSatisfy { Set($0.keys) == ["id", "name", "address", "port"] }, "records hold no token")
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
        model.stop()
        check(model.found.isEmpty, "stopping clears the list")
        print("PASS: device pairing: the Mac and its fleet added with one token, wrong code, repeated pairing, revoked identity renewed, an older pairing offered its own token and keeping the shared one until it is saved, scanned QR")
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

/// What the fake Macs of one fleet share: the code showing, the devices known (hashes of their tokens), the shared
/// token, and what was heard.
final class FakeFleet: @unchecked Sendable {
    private let lock = NSLock()
    let hostID = UUID()
    let sharedToken = "shared-token"
    var members: [FakeMac] = []
    private var _code = "", _accepted: [String] = [], _devices: [FleetDeviceIntroduction] = [], _revoked = Set<UUID>()
    private var _enrollments = 0, _retired = false, _refuses = false, _heard: [String] = []

    var code: String { get { lock.withLock { _code } } set { lock.withLock { _code = newValue } } }
    var accepted: [String] { lock.withLock { _accepted } }
    var devices: [FleetDeviceIntroduction] { lock.withLock { _devices } }
    var enrollments: Int { get { lock.withLock { _enrollments } } set { lock.withLock { _enrollments = newValue } } }
    var sharedTokenRetired: Bool { get { lock.withLock { _retired } } set { lock.withLock { _retired = newValue } } }
    var refusesEnrollment: Bool { get { lock.withLock { _refuses } } set { lock.withLock { _refuses = newValue } } }
    var heard: [String] { lock.withLock { _heard } }

    func heard(_ line: String) { lock.withLock { _heard.append(line) } }
    func revoke(_ id: UUID) { lock.withLock { _revoked.insert(id) } }
    func isRevoked(_ id: UUID) -> Bool { lock.withLock { _revoked.contains(id) } }
    func take(_ device: FleetDeviceIntroduction) {
        lock.withLock {
            if !_accepted.contains(device.tokenHash) { _accepted.append(device.tokenHash); _devices.append(device) }
        }
    }
    func accepts(_ token: String) -> Bool {
        lock.withLock { (token == sharedToken && !_retired) || _accepted.contains(FleetProtocol.hash(token)) }
    }
}

/// One Mac's listener, answering on a thread per connection.
final class FakeMac: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    let name: String
    let fleet: FakeFleet
    private let stopped = Locked(false)

    init(name: String, fleet: FakeFleet) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(fd >= 0 && bound == 0 && listen(fd, 16) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        (self.fd, self.name, self.fleet) = (fd, name, fleet)
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in accepting() }
    }

    func stop() {
        stopped.value = true
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func accepting() {
        while !stopped.value {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var shared = false
        while let line = readLine(client) {
            fleet.heard(String(decoding: line, as: UTF8.self))
            guard let request = try? NDJSON.decode(RemoteRequest.self, from: line) else { return }
            switch request {
            case .fleetIdentify(let id):
                write(client, .fleetIdentity(id: id, hostID: fleet.hostID, name: name, build: nil, fleetEnabled: true))
            case .fleetPairDevice(let id, let code, let device):
                if fleet.isRevoked(device.deviceID) {
                    write(client, .error(id: id, code: FleetProtocol.Code.deviceRevoked, message: "revoked"))
                } else if code != fleet.code {
                    write(client, .error(id: id, code: FleetProtocol.Code.badCode, message: "That code isn't right."))
                } else {
                    fleet.take(device)
                    let members = fleet.members.filter { $0 !== self }.map { FleetMember(hostID: UUID(), name: $0.name, host: "127.0.0.1", port: $0.port) }
                    write(client, .fleetDevices(id: id, result: FleetDevicesResult(hostID: fleet.hostID, name: name, members: members)))
                }
            case .fleetEnrollDevice(let id, let device):
                fleet.enrollments += 1
                if fleet.refusesEnrollment {
                    write(client, .error(id: id, code: "save_failed", message: "No."))
                } else if fleet.isRevoked(device.deviceID) {
                    write(client, .error(id: id, code: FleetProtocol.Code.deviceRevoked, message: "revoked"))
                } else {
                    fleet.take(device)
                    write(client, .fleetDevices(id: id, result: FleetDevicesResult(hostID: fleet.hostID, name: name)))
                }
            case .hello(let id, let token, _, _, _):
                guard fleet.accepts(token) else {
                    write(client, .error(id: id, code: RemoteProtocol.unauthorizedCode, message: "bad token"))
                    return
                }
                shared = token == fleet.sharedToken
                write(client, .helloOk(id: id, protocolVersion: RemoteProtocol.version,
                                       capabilities: [RemoteProtocol.nativeThreadCapability] + (shared ? [RemoteProtocol.fleetDevicesCapability] : []), hostID: fleet.hostID))
            case .stateFetch(let id):
                write(client, .state(id: id, state: ShepherdState()))
            default:
                break
            }
        }
    }

    private func readLine(_ fd: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == 10 { return line }
            line.append(byte)
        }
        return nil
    }

    private func write(_ fd: Int32, _ reply: RemoteReply) {
        guard let data = try? NDJSON.encode(reply) else { return }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) }
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

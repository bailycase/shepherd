import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Fake Macs of a fleet for the iOS client checks (`FleetDevicePairingCheck`, `FleetViewCheck`): a listener per Mac over
// real TCP, answering what a host answers a device. Shared by the checks that name it in run.sh.

/// What the fake Macs of one fleet share: the code showing, the devices known (hashes of their tokens), the shared
/// token, and what was heard.
final class FakeFleet: @unchecked Sendable {
    private let lock = NSLock()
    var hostID = UUID()
    let sharedToken = "shared-token"
    var members: [FakeMac] = []
    private var _code = "", _accepted: [String] = [], _devices: [FleetDeviceIntroduction] = [], _revoked = Set<UUID>()
    private var _enrollments = 0, _retired = false, _refuses = false, _heard: [String] = []
    private var _view: FleetSnapshot?, _weights: [String: FleetSendWeight] = [:], _watching: [Bool] = [], _changes: [HostSettingChange] = []

    /// The fleet this Mac serves a device (`fleet.view.v1`); nil: Fleet is off here.
    var view: FleetSnapshot? { get { lock.withLock { _view } } set { lock.withLock { _view = newValue } } }
    /// The Send work here weights its host settings hold.
    var weights: [String: FleetSendWeight] { lock.withLock { _weights } }
    /// Every `watching(_)` a device sent, and every host setting change it made, in order.
    var watching: [Bool] { lock.withLock { _watching } }
    var changes: [HostSettingChange] { lock.withLock { _changes } }
    func watched(_ on: Bool) { lock.withLock { _watching.append(on) } }
    func changed(_ change: HostSettingChange) {
        lock.withLock {
            _changes.append(change)
            if case .fleetWeight(let hostID, let weight) = change { _weights[FleetSendWeight.settingKey(hostID: hostID)] = weight }
        }
    }

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
    private let open = Locked<[Int32]>([])

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

    /// Tells every connected client the host offers `capabilities` now (Fleet switched off).
    func push(capabilities: [String]) {
        guard let data = try? NDJSON.encode(RemoteReply.capabilitiesChanged(capabilities: capabilities)) else { return }
        for client in open.value { _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, data.count) } }
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
        open.value.append(client)
        defer {
            open.value.removeAll { $0 == client }
            close(client)
        }
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
                var capabilities = [RemoteProtocol.nativeThreadCapability] + (shared ? [RemoteProtocol.fleetDevicesCapability] : [])
                if fleet.view != nil { capabilities += [RemoteProtocol.fleetViewCapability, RemoteProtocol.hostSettingsCapability] }
                write(client, .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: capabilities, hostID: fleet.hostID))
            case .stateFetch(let id):
                write(client, .state(id: id, state: ShepherdState()))
            case .fleetRead(let id):
                if let view = fleet.view { write(client, .fleetResult(id: id, result: FleetResult(snapshot: view))) }
                else { write(client, .error(id: id, code: FleetProtocol.Code.off, message: "Enable Fleet in Settings ▸ Experiments.")) }
            case .fleetAction(let id, .watching(let on)):
                fleet.watched(on)
                write(client, .fleetResult(id: id, result: FleetResult(snapshot: fleet.view ?? FleetSnapshot())))
            case .hostSettings(let id, let command):
                var settings = HostSettings(fleetWeights: fleet.weights)
                if case .change(let change) = command {
                    fleet.changed(change)
                    settings.apply(change)
                }
                write(client, .hostSettings(id: id, settings: settings))
            case .fleetSync(let id, _), .fleetPressure(let id, _), .fleetReadiness(let id, _), .fleetPressureNow(let id), .fleetAction(let id, _):
                write(client, .error(id: id, code: FleetProtocol.Code.forbidden, message: "A device is not a member."))
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

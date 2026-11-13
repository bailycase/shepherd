import Foundation
import ShepherdProtocol

/// Finding Macs on networks where Bonjour carries Apple's own service types but not
/// `_shepherd._tcp` (a VLAN behind an mDNS reflector). The devices that announce those types are
/// asked once whether Shepherd answers; the ones that do join Add a Mac's list.
public enum FleetNeighbors {
    /// What Apple's own services announce on most networks that reflect mDNS at all: a Mac with
    /// Remote Login on, any Apple device nearby, any Apple device with a model name. Each type
    /// must be in the app's `NSBonjourServices` (an app without it cannot browse the type).
    public static let types = ["_ssh._tcp", "_companion-link._tcp", "_device-info._tcp"]

    /// The listener ports probed on each device: this build's first, then the other edition's.
    public static var ports: [UInt16] {
        let own = ShepherdEdition.current.defaultRemoteListenerPort
        return [own] + ShepherdEdition.allCases.map(\.defaultRemoteListenerPort).filter { $0 != own }
    }

    /// How a device that answered is listed, in the same row as one found by `_shepherd._tcp`.
    static func found(_ identity: RemoteHostClient.FleetPeerIdentity, address: String, port: UInt16) -> FoundMac {
        FoundMac(id: "probe-\(address):\(port)", name: identity.name, version: identity.build,
                 idHash: FleetProtocol.advertisedIDHash(identity.hostID), address: address, port: port)
    }

    /// The list Add a Mac shows: every Mac `_shepherd._tcp` found that resolved, then each Mac only a
    /// probe found. A Mac seen both ways (the same id hash, or the same address and port) shows once, as
    /// Bonjour's own record, which carries the version it announces.
    static func merged(bonjour: [FoundMac], probed: [FoundMac]) -> [FoundMac] {
        let ready = bonjour.filter { $0.address != nil }
        // An entry that has not resolved yet still counts: its Mac must not flash up as a second row meanwhile.
        var hashes = Set(bonjour.compactMap(\.idHash))
        var places = Set(ready.map { "\($0.address ?? ""):\($0.port ?? 0)" })
        var extra: [FoundMac] = []
        for mac in probed.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) {
            let place = "\(mac.address ?? ""):\(mac.port ?? 0)"
            // Two addresses of one Mac (two interfaces) are one entry.
            guard !places.contains(place), mac.idHash.map({ hashes.insert($0).inserted }) ?? true else { continue }
            places.insert(place)
            extra.append(mac)
        }
        return (ready + extra).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

/// Asks each device address it is shown, once, whether Shepherd answers, a few at a time. Runs on
/// the main actor; the probe itself is a plain async call (`RemoteHostClient.fleetProbe`).
@MainActor
final class FleetNeighborProber {
    typealias Probe = @Sendable (String, UInt16) async -> RemoteHostClient.FleetPeerIdentity?

    private let ports: [UInt16]
    private let limit: Int
    private let probe: Probe
    private let skip: (String) -> Bool
    private let changed: () -> Void
    private var seen: Set<String> = []
    private var waiting: [String] = []
    private var running: [String: Task<Void, Never>] = [:]
    private var stopped = false
    /// The Macs that answered, by the address that did.
    private(set) var answered: [String: FoundMac] = [:]

    /// `skip` says an address is already listed (by `_shepherd._tcp`) and needs no probe.
    init(ports: [UInt16], limit: Int = 4, probe: @escaping Probe, skip: @escaping (String) -> Bool = { _ in false },
         changed: @escaping () -> Void) {
        self.ports = ports
        self.limit = max(1, limit)
        self.probe = probe
        self.skip = skip
        self.changed = changed
    }

    /// A device announced itself at `address`. The same address is never probed twice.
    func see(address: String) {
        guard !stopped, seen.insert(address).inserted else { return }
        waiting.append(address)
        next()
    }

    func stop() {
        stopped = true
        for task in running.values { task.cancel() }
        running = [:]
        waiting = []
        answered = [:]
    }

    /// Returns once every address seen so far has been probed (a test waits on this, not on a clock).
    func settle() async {
        while let task = running.values.first { await task.value }
    }

    private func next() {
        while !stopped, running.count < limit, !waiting.isEmpty {
            let address = waiting.removeFirst()
            guard !skip(address) else { continue }
            running[address] = Task { [probe, ports] in
                var mac: FoundMac?
                for port in ports where mac == nil && !Task.isCancelled {
                    mac = await probe(address, port).map { FleetNeighbors.found($0, address: address, port: port) }
                }
                self.finished(address, mac)
            }
        }
    }

    private func finished(_ address: String, _ mac: FoundMac?) {
        guard !stopped else { return }
        running[address] = nil
        if let mac {
            answered[address] = mac
            changed()
        }
        next()
    }
}

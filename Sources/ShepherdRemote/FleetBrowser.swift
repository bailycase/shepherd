import Foundation
import Network
import ShepherdProtocol

/// A Mac running Shepherd that Bonjour found (`_shepherd._tcp`), for Settings ▸ Fleet ▸ Add a Mac and
/// for a phone's or iPad's Add a Mac.
public struct FoundMac: Identifiable, Equatable, Sendable {
    /// The Bonjour service's name and where it was found: stable while it is on the network.
    public let id: String
    public var name: String
    /// "1.9": what it says of its Shepherd, when it says.
    public var version: String?
    /// `FleetProtocol.advertisedIDHash` of its host id: a Mac skips its own entry, and one it already has.
    public var idHash: String?
    /// Where it listens, once resolved: an IPv4 address and the port.
    public var address: String?
    public var port: UInt16?

    public init(id: String, name: String, version: String? = nil, idHash: String? = nil, address: String? = nil, port: UInt16? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.idHash = idHash
        self.address = address
        self.port = port
    }
}

/// Finds Macs by Bonjour while the Add a Mac sheet is open, and resolves each to an address by
/// connecting to it once (a connection that sends nothing and closes at once). The host makes the
/// real connection; this only fills the list. It runs in the app, which holds the Local Network
/// permission, and stops with the sheet.
///
/// A network that reflects mDNS between subnets often passes Apple's own types (`_ssh._tcp`,
/// `_companion-link._tcp`, `_device-info._tcp`) but not `_shepherd._tcp`. So the browser also
/// looks at the devices announcing those (`FleetNeighbors`), and asks each address once whether
/// Shepherd answers (`RemoteHostClient.fleetProbe`). Those that do are listed like any other Mac.
/// Nothing else is probed: no subnet, port or disk scan.
@MainActor
public final class FleetBrowser {
    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: FoundMac] = [:]
    private let queue = DispatchQueue(label: "shepherd.fleet.browser")
    private var onChange: (([FoundMac]) -> Void)?
    private let shepherdType: String?
    private let neighborTypes: [String]
    private let probePorts: [UInt16]
    private let probe: FleetNeighborProber.Probe
    private var lookup: FleetNeighborLookup?
    private var prober: FleetNeighborProber?

    public convenience init() {
        self.init(neighborTypes: FleetNeighbors.types, probePorts: FleetNeighbors.ports)
    }

    /// `neighborTypes` are the Bonjour types whose devices are probed, on `probePorts`; tests pass their own.
    /// `shepherdType` nil skips `_shepherd._tcp` (a test must not reach a Shepherd that is running on the machine).
    init(shepherdType: String? = FleetProtocol.bonjourType, neighborTypes: [String], probePorts: [UInt16],
         probe: @escaping FleetNeighborProber.Probe = { await RemoteHostClient.fleetProbe(host: $0, port: $1) }) {
        self.shepherdType = shepherdType
        self.neighborTypes = neighborTypes
        self.probePorts = probePorts
        self.probe = probe
    }

    /// Starts browsing; `onChange` hears the list, sorted by name, each time it changes.
    public func start(_ onChange: @escaping ([FoundMac]) -> Void) {
        stop()
        self.onChange = onChange
        if let shepherdType {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: shepherdType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let entries = results.map { ($0.endpoint, Self.entry(of: $0)) }
                Task { @MainActor in self?.update(entries) }
            }
            browser.start(queue: queue)
            self.browser = browser
        }
        startNeighbors()
    }

    private func startNeighbors() {
        guard !neighborTypes.isEmpty else { return }
        let prober = FleetNeighborProber(
            ports: probePorts, probe: probe,
            skip: { [weak self] address in self?.found.values.contains { $0.address == address } ?? true },
            changed: { [weak self] in self?.publish() })
        self.prober = prober
        let lookup = FleetNeighborLookup { address in
            Task { @MainActor in prober.see(address: address) }
        }
        lookup.start(types: neighborTypes)
        self.lookup = lookup
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for connection in resolving.values { connection.cancel() }
        resolving = [:]
        found = [:]
        onChange = nil
        lookup?.stop()
        lookup = nil
        prober?.stop()
        prober = nil
    }

    private nonisolated static func entry(of result: NWBrowser.Result) -> FoundMac {
        var name = "", id: String?, version: String?
        if case .service(let service, _, _, _) = result.endpoint { name = service }
        if case .bonjour(let record) = result.metadata {
            if let shown = record["name"], !shown.isEmpty { name = shown }
            id = record["id"]
            version = record["version"]
        }
        return FoundMac(id: "\(result.endpoint)", name: name, version: version, idHash: id)
    }

    private func update(_ entries: [(NWEndpoint, FoundMac)]) {
        let current = Set(entries.map(\.0))
        for gone in found.keys where !current.contains(gone) {
            found[gone] = nil
            resolving.removeValue(forKey: gone)?.cancel()
        }
        for (endpoint, entry) in entries {
            // Keep what resolving learned; refresh what the record says.
            var merged = entry
            merged.address = found[endpoint]?.address
            merged.port = found[endpoint]?.port
            found[endpoint] = merged
            if merged.address == nil, resolving[endpoint] == nil { resolve(endpoint) }
        }
        publish()
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection, case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return }
            let address = Self.text(of: host)
            connection.cancel()
            Task { @MainActor in self?.resolved(endpoint, address: address, port: port.rawValue) }
        }
        connection.start(queue: queue)
    }

    private nonisolated static func text(of host: NWEndpoint.Host) -> String {
        // "192.168.1.52%en0": the interface scope is not part of the address a host dials.
        "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
    }

    private func resolved(_ endpoint: NWEndpoint, address: String, port: UInt16) {
        resolving[endpoint] = nil
        guard found[endpoint] != nil else { return }
        found[endpoint]?.address = address
        found[endpoint]?.port = port
        publish()
    }

    private func publish() {
        // Only Macs that resolved can be picked.
        onChange?(FleetNeighbors.merged(bonjour: Array(found.values), probed: prober.map { Array($0.answered.values) } ?? []))
    }
}

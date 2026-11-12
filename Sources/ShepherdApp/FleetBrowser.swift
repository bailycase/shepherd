import Foundation
import Network
import ShepherdProtocol

/// A Mac running Shepherd that Bonjour found (`_shepherd._tcp`), for Settings ▸ Fleet ▸ Add a Mac.
struct FoundMac: Identifiable, Equatable, Sendable {
    /// The Bonjour service's name and where it was found: stable while it is on the network.
    let id: String
    var name: String
    /// "1.9": what it says of its Shepherd, when it says.
    var version: String?
    /// `FleetProtocol.advertisedIDHash` of its host id: a Mac skips its own entry, and one it already has.
    var idHash: String?
    /// Where it listens, once resolved: an IPv4 address and the port.
    var address: String?
    var port: UInt16?
}

/// Finds Macs by Bonjour while the Add a Mac sheet is open, and resolves each to an address by
/// connecting to it once (a connection that sends nothing and closes at once). The host makes the
/// real connection; this only fills the list. It runs in the app, which holds the Local Network
/// permission, and stops with the sheet.
@MainActor
final class FleetBrowser {
    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: FoundMac] = [:]
    private let queue = DispatchQueue(label: "shepherd.fleet.browser")
    private var onChange: (([FoundMac]) -> Void)?

    /// Starts browsing; `onChange` hears the list, sorted by name, each time it changes.
    func start(_ onChange: @escaping ([FoundMac]) -> Void) {
        stop()
        self.onChange = onChange
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: FleetProtocol.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries = results.map { ($0.endpoint, Self.entry(of: $0)) }
            Task { @MainActor in self?.update(entries) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for connection in resolving.values { connection.cancel() }
        resolving = [:]
        found = [:]
        onChange = nil
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
        onChange?(found.values.filter { $0.address != nil }.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
    }
}

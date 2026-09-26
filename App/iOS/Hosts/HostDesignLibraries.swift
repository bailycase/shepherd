import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Every host's designs as this device reaches them (docs/designs.md › Remote): one
/// `RemoteDesignLibrary` per host over one file cache, shared by the iPhone's designs
/// (`MobileDesigns`) and the iPad's (`PadDesigns`). A host keeps one set of watched designs per
/// connection, so the stores say which designs each has on screen and the host is told them
/// all; its pushes (`MobileHost.onDesignChanged`) reach every store.
@MainActor
final class HostDesignLibraries {
    let cache: RemoteDesignCache
    private var libraries: [UUID: RemoteDesignLibrary] = [:]
    /// Each library's connection as last handed to it: the session, and whether it offers designs.
    private var connections: [UUID: (session: UUID?, offers: Bool)] = [:]
    /// The designs each store has on screen, by host.
    private var watching: [UUID: [String: Set<DesignID>]] = [:]
    private var observers: [String: (UUID, DesignID, UInt64?, UInt64?) -> Void] = [:]

    private static var shared: [ObjectIdentifier: HostDesignLibraries] = [:]

    /// The libraries of the app's hosts: one per `MobileHosts`, made on first use.
    static func of(_ hosts: MobileHosts) -> HostDesignLibraries {
        if let libraries = shared[ObjectIdentifier(hosts)] { return libraries }
        let libraries = HostDesignLibraries()
        shared[ObjectIdentifier(hosts)] = libraries
        return libraries
    }

    private init() {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ShepherdDesigns", isDirectory: true)
        cache = RemoteDesignCache(directory: folder, memoryBudget: 48 * 1024 * 1024)
    }

    /// The host's library, made on first use.
    func library(_ host: UUID) -> RemoteDesignLibrary {
        if let library = libraries[host] { return library }
        let library = RemoteDesignLibrary(hostID: host, cache: cache)
        libraries[host] = library
        return library
    }

    /// Hands the host's library its connection while it is connected and offers `designs.v1`,
    /// and takes the host's pushes. Every store calls it as it sees the host change; only a new
    /// connection or a change in what it offers reaches the library.
    func connect(_ host: MobileHost) {
        let client = host.connectedClient
        let offers = client != nil && host.supports(RemoteProtocol.designsCapability)
        let next = (session: client == nil ? nil : host.session, offers: offers)
        if let last = connections[host.id], last.session == next.session, last.offers == next.offers { return }
        connections[host.id] = next
        library(host.id).connect(offers ? client : nil, available: offers)
        let id = host.id
        host.onDesignChanged = { [weak self] design, revision, comments in
            guard let self else { return }
            for observer in self.observers.values { observer(id, design, revision, comments) }
        }
    }

    /// A host this device no longer knows.
    func forget(_ host: UUID) {
        libraries.removeValue(forKey: host)?.connect(nil, available: false)
        connections[host] = nil
        watching[host] = nil
    }

    /// The designs `owner` has on screen on `host`: the host pushes changes for every store's.
    func watch(_ designs: Set<DesignID>, on host: UUID, for owner: String) {
        watching[host, default: [:]][owner] = designs.isEmpty ? nil : designs
        library(host).watch(watching[host]?.values.reduce(into: Set<DesignID>()) { $0.formUnion($1) } ?? [])
    }

    /// `owner` hears every host's pushes for the designs watched: the host, the design, its
    /// files' revision, its comments' revision.
    func observe(_ owner: String, _ observer: @escaping (UUID, DesignID, UInt64?, UInt64?) -> Void) {
        observers[owner] = observer
    }
}

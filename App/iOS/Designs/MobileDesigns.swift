import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Every host's designs on the phone (designs track): each host's `RemoteDesignLibrary` (shared
/// with the iPad's designs, `HostDesignLibraries`), following each host's connection and its
/// Design tool as it turns on and off (`designs.v1`). Views read `model` (the Designs screen's tiles and systems), each design's
/// index and comments, and what a host says it serves; they never derive rows.
///
/// A host that doesn't offer `designs.v1` (an older Shepherd, or its Design tool off) shows no
/// design surface at all. Rendering happens on the phone, from files fetched by hash.
@MainActor
@Observable
final class MobileDesigns {
    /// Everything the Designs screen draws; written only when it changes.
    private(set) var model = RemoteDesignsModel()
    /// Each design's index as last synced, and the files its boards load.
    private(set) var indexes: [HostDesignRef: RemoteDesignIndex] = [:]
    private(set) var comments: [HostDesignRef: DesignComments] = [:]
    /// Why a design couldn't be read, by design.
    private(set) var failures: [HostDesignRef: String] = [:]
    /// Each system's colors, for its row's swatches (`host/namespace`).
    private(set) var swatches: [String: [String]] = [:]
    /// The hosts serving designs now.
    private(set) var serving: Set<UUID> = []

    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private let libraries: HostDesignLibraries
    /// Each host's connection as last seen, and whether it offered designs.
    @ObservationIgnored private var connections: [UUID: (session: UUID?, serves: Bool)] = [:]
    @ObservationIgnored private var signatures: [UUID: String] = [:]
    /// The screens watching each design, by their tokens: a design is watched while any is.
    @ObservationIgnored private var watchers: [HostDesignRef: Set<UUID>] = [:]
    @ObservationIgnored private var listing: Set<UUID> = []
    @ObservationIgnored private var again: Set<UUID> = []
    /// Called when a watched design changed on its host, with what moved.
    @ObservationIgnored private var observers: [UUID: (HostDesignRef, Bool, Bool) -> Void] = [:]

    private static var stores: [ObjectIdentifier: MobileDesigns] = [:]

    /// The designs of the app's hosts: one per `MobileHosts`, made on first use.
    static func of(_ hosts: MobileHosts) -> MobileDesigns {
        if let store = stores[ObjectIdentifier(hosts)] { return store }
        let store = MobileDesigns(hosts: hosts)
        stores[ObjectIdentifier(hosts)] = store
        return store
    }

    static func forget(host: UUID, in hosts: MobileHosts) {
        guard let store = stores[ObjectIdentifier(hosts)] else { return }
        for (ref, tokens) in store.watchers where ref.host == host {
            for token in tokens { store.observers[token] = nil }
        }
        store.watchers = store.watchers.filter { $0.key.host != host }
        store.indexes = store.indexes.filter { $0.key.host != host }
        store.comments = store.comments.filter { $0.key.host != host }
        store.failures = store.failures.filter { $0.key.host != host }
        store.swatches = store.swatches.filter { !$0.key.hasPrefix(host.uuidString + "/") }
        store.connections[host] = nil
        store.signatures[host] = nil
        store.again.remove(host)
        store.setServing(host, false)
        store.derive()
        DesignRendering.shared.forget(host: host)
    }

    private init(hosts: MobileHosts) {
        self.hosts = hosts
        libraries = HostDesignLibraries.of(hosts)
        libraries.observe("phone") { [weak self] host, design, revision, comments in
            self?.changed(HostDesignRef(host: host, design: design), files: revision != nil, comments: comments != nil)
        }
        track()
    }

    // MARK: Hosts

    /// Reads the hosts under observation tracking, follows each new connection and what it
    /// offers, and tracks again. A host serves designs while it is connected and offers
    /// `designs.v1` (its Design tool on); MobileHosts follows `capabilitiesChanged`.
    private func track() {
        let inputs = withObservationTracking {
            hosts.hosts.filter { !libraries.cache.isForgotten(host: $0.id) }.map { host in
                (host: host, session: host.session,
                 serves: host.connectedClient != nil && host.supports(RemoteProtocol.designsCapability),
                 signature: host.state.designs.map { "\($0.id.rawValue)/\($0.lastActiveAt)/\($0.boardCount ?? -1)/\($0.agentID?.rawValue ?? "")" }
                    .joined(separator: ",") + "|" + host.state.agents.filter { $0.designID != nil }
                    .map { "\($0.id.rawValue):\($0.status.rawValue)" }.joined(separator: ","))
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        let live = Set(inputs.map(\.host.id))
        for id in Set(connections.keys).subtracting(live) {
            libraries.forget(id)
            Self.forget(host: id, in: hosts)
        }
        var changed = false
        for input in inputs {
            let id = input.host.id
            libraries.connect(input.host)
            let connection = (session: input.session, serves: input.serves)
            if connections[id]?.session != connection.session || connections[id]?.serves != connection.serves {
                connections[id] = connection
                setServing(id, input.serves)
                changed = true
                if input.serves { Task { await list(id) } }
            }
            if signatures[id] != input.signature {
                signatures[id] = input.signature
                changed = true
                if input.serves { Task { await list(id) } }
            }
        }
        if changed { derive() }
    }

    private func setServing(_ id: UUID, _ serves: Bool) {
        var next = serving
        if serves { next.insert(id) } else { next.remove(id) }
        if next != serving { serving = next }
    }

    func library(_ host: UUID) -> RemoteDesignLibrary? {
        serving.contains(host) && !libraries.cache.isForgotten(host: host) ? libraries.library(host) : nil
    }

    func source(_ ref: HostDesignRef) -> RemoteDesignSource? {
        library(ref.host)?.source(ref.design)
    }

    // MARK: Reading

    /// Lists every serving host's designs again (pull to refresh, the Designs screen appearing).
    func refresh() async {
        for id in serving { await list(id) }
    }

    /// Lists one host's designs; a request while one is under way lists once more after it.
    private func list(_ id: UUID) async {
        guard let library = library(id) else { return }
        guard !listing.contains(id) else {
            again.insert(id)
            return
        }
        listing.insert(id)
        defer { listing.remove(id) }
        repeat {
            again.remove(id)
            await library.refresh()
            derive()
        } while again.contains(id)
        await readSwatches(id)
    }

    private func derive() {
        let serving = hosts.hosts.filter { self.serving.contains($0.id) && $0.phase.isConnected }
        let next = RemoteDesignsModel(hosts: serving.map { host in
            RemoteDesignsModel.Host(id: host.id, name: host.name, listing: library(host.id)?.listing, state: host.state)
        }, now: Date())
        if next != model { model = next }
        DesignRendering.shared.prune(keeping: Set(next.tiles.map(\.ref)))
    }

    /// Reads each listed system once for its row's colors.
    private func readSwatches(_ id: UUID) async {
        guard let library = library(id), let systems = library.listing?.systems else { return }
        for system in systems {
            let key = "\(id.uuidString)/\(system.namespace)"
            guard swatches[key] == nil, case .system(let read)? = try? await library.request(.system(namespace: system.namespace)) else { continue }
            swatches[key] = DesignSystemPresentation.swatches(read.tokens, count: 3).map(\.light)
        }
    }

    /// A design system whole (its screen).
    func system(host: UUID, namespace: String) async throws -> DesignSystemRead {
        guard let library = library(host) else { throw RemoteHostClientError.rejected(code: "designs_off", message: RemoteHostClient.designsRefusal) }
        guard case .system(let read) = try await library.request(.system(namespace: namespace)) else { throw MobileDesignsError.unexpected }
        return read
    }

    /// Reads a design's index and fetches the files whose hashes this phone lacks.
    @discardableResult
    func sync(_ ref: HostDesignRef) async -> RemoteDesignIndex? {
        guard !libraries.cache.isForgotten(host: ref.host) else { return nil }
        guard let source = source(ref) else { return indexes[ref] }
        do {
            let index = try await source.sync()
            guard !libraries.cache.isForgotten(host: ref.host) else { return nil }
            if indexes[ref] != index { indexes[ref] = index }
            if failures[ref] != nil { failures[ref] = nil }
            return index
        } catch {
            guard !libraries.cache.isForgotten(host: ref.host) else { return nil }
            failures[ref] = MobileDesignsError.words(error)
            return indexes[ref]
        }
    }

    func loadComments(_ ref: HostDesignRef) async {
        guard let library = library(ref.host),
              case .comments(let next)? = try? await library.request(.comments(designID: ref.design)) else { return }
        if comments[ref] != next { comments[ref] = next }
    }

    // MARK: Watching

    /// A design came on screen (`on`) or left it: its host pushes changes for the designs on
    /// screen alone, and `observer` hears them.
    /// Screens stack (a design, its board over it), so a design stays watched until the last
    /// screen showing it leaves.
    func watch(_ ref: HostDesignRef, on: Bool, token: UUID, observer: ((HostDesignRef, Bool, Bool) -> Void)? = nil) {
        guard !libraries.cache.isForgotten(host: ref.host) else { return }
        if on {
            watchers[ref, default: []].insert(token)
            observers[token] = observer
        } else {
            watchers[ref]?.remove(token)
            if watchers[ref]?.isEmpty == true { watchers[ref] = nil }
            observers[token] = nil
        }
        libraries.watch(Set(watchers.keys.filter { $0.host == ref.host }.map(\.design)), on: ref.host, for: "phone")
    }

    private func changed(_ ref: HostDesignRef, files: Bool, comments: Bool) {
        for observer in observers.values { observer(ref, files, comments) }
        if files { Task { await list(ref.host) } }
    }

    // MARK: Changing

    /// Pins a comment on the host, as its own canvas does; answers it as kept.
    func addComment(_ ref: HostDesignRef, draft: DesignCommentDraft) async throws -> DesignComment {
        guard let library = library(ref.host) else { throw MobileDesignsError.offline }
        let base = comments[ref]?.revision
        let result: RemoteDesignResult
        do {
            result = try await library.request(.addComment(designID: ref.design, draft: draft, baseRevision: base))
        } catch RemoteHostClientError.rejected(let code, _) where code == "stale_revision" {
            // The comments moved on: read them again and pin it once more.
            await loadComments(ref)
            result = try await library.request(.addComment(designID: ref.design, draft: draft, baseRevision: comments[ref]?.revision))
        }
        guard case .comment(let comment, let undelivered) = result else { throw MobileDesignsError.unexpected }
        await loadComments(ref)
        if let undelivered { throw MobileDesignsError.undelivered(undelivered) }
        return comment
    }

    /// Makes a design on `host` as its New design does; answers the design.
    func create(host: UUID, brief: String, system: String?) async throws -> HostDesignRef {
        guard let library = library(host) else { throw MobileDesignsError.offline }
        guard case .created(let id, _) = try await library.request(.create(RemoteDesignCreate(brief: brief, systemNamespace: system))) else {
            throw MobileDesignsError.unexpected
        }
        await list(host)
        return HostDesignRef(host: host, design: id)
    }

    // MARK: Lookups

    func design(_ ref: HostDesignRef) -> Design? {
        hosts.host(ref.host)?.state.designs.first { $0.id == ref.design }
            ?? library(ref.host)?.listing?.designs.first { $0.id == ref.design }?.design
    }

    /// The agent that draws it, while its host has one.
    func agent(_ ref: HostDesignRef) -> AgentRef? {
        guard let host = hosts.host(ref.host) else { return nil }
        let design = design(ref)
        let agent = host.state.agents.first { $0.id == design?.agentID } ?? host.state.agents.first { $0.designID == ref.design }
        return agent.map { AgentRef(host: ref.host, agent: $0.id) }
    }

    func agentWorking(_ ref: HostDesignRef) -> Bool {
        guard let agent = agent(ref) else { return false }
        return hosts.agent(agent)?.status == .working
    }

    func summary(_ ref: HostDesignRef) -> RemoteDesignSummary? {
        library(ref.host)?.listing?.designs.first { $0.id == ref.design }
    }
}

enum MobileDesignsError: Error, CustomStringConvertible {
    case offline
    case unexpected
    /// Kept on the host, but it didn't reach the design agent.
    case undelivered(String)

    var description: String {
        switch self {
        case .offline: "The host isn't serving designs right now."
        case .unexpected: "The host answered something unexpected."
        case .undelivered(let why): "The comment is kept, but it didn't reach the design agent: \(why)"
        }
    }

    static func words(_ error: Error) -> String {
        switch error {
        case RemoteHostClientError.rejected(_, let message): message
        case let error as MobileDesignsError: error.description
        default: String(describing: error)
        }
    }
}

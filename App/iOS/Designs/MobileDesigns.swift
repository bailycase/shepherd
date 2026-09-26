import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Every host's designs on the phone (designs track): one `RemoteDesignLibrary` per host over a
/// shared file cache, following each host's connection and its Design tool as it turns on and
/// off (`designs.v1`). Views read `model` (the Designs screen's tiles and systems), each design's
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
    @ObservationIgnored let cache: RemoteDesignCache
    @ObservationIgnored private var libraries: [UUID: RemoteDesignLibrary] = [:]
    @ObservationIgnored private var sessions: [UUID: UUID] = [:]
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

    private init(hosts: MobileHosts) {
        self.hosts = hosts
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("designs", isDirectory: true)
        cache = RemoteDesignCache(directory: folder, memoryBudget: MobileDesignLayout.cacheMemoryBudget)
        track()
    }

    // MARK: Hosts

    /// Reads the hosts under observation tracking, follows each new connection, and tracks again.
    private func track() {
        let inputs = withObservationTracking {
            hosts.hosts.map { host in
                (id: host.id, session: host.session, client: host.connectedClient,
                 signature: host.state.designs.map { "\($0.id.rawValue)/\($0.lastActiveAt)/\($0.boardCount ?? -1)/\($0.agentID?.rawValue ?? "")" }
                    .joined(separator: ",") + "|" + host.state.agents.filter { $0.designID != nil }
                    .map { "\($0.id.rawValue):\($0.status.rawValue)" }.joined(separator: ","))
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        let live = Set(inputs.map(\.id))
        for id in Set(libraries.keys).subtracting(live) {
            libraries.removeValue(forKey: id)?.connect(nil, available: false)
            sessions[id] = nil
            signatures[id] = nil
        }
        var changed = false
        for input in inputs {
            let library = libraries[input.id] ?? {
                let made = RemoteDesignLibrary(hostID: input.id, cache: cache)
                libraries[input.id] = made
                return made
            }()
            if sessions[input.id] != input.session {
                sessions[input.id] = input.session
                follow(input.id, client: input.client, library: library)
                changed = true
            }
            if signatures[input.id] != input.signature {
                signatures[input.id] = input.signature
                changed = true
                if library.available { Task { await list(input.id) } }
            }
        }
        if changed { derive() }
    }

    /// A host's new connection (or none): its library takes it, pushes come here, and a host that
    /// serves designs lists them.
    private func follow(_ id: UUID, client: RemoteHostClient?, library: RemoteDesignLibrary) {
        let serves = client?.capabilities.contains(RemoteProtocol.designsCapability) == true
        library.connect(client, available: serves)
        setServing(id, serves)
        guard let client else { return }
        client.onCapabilitiesChanged = { [weak self, weak client] capabilities in
            MainActor.assumeIsolated {
                guard let self, let client, self.hosts.host(id)?.connectedClient === client else { return }
                let serves = capabilities.contains(RemoteProtocol.designsCapability)
                library.connect(client, available: serves)
                self.setServing(id, serves)
                if serves { Task { await self.list(id) } } else { self.derive() }
            }
        }
        client.onDesignChanged = { [weak self, weak client] design, revision, comments in
            MainActor.assumeIsolated {
                guard let self, let client, self.hosts.host(id)?.connectedClient === client else { return }
                self.changed(HostDesignRef(host: id, design: design), files: revision != nil, comments: comments != nil)
            }
        }
        if serves { Task { await list(id) } }
    }

    private func setServing(_ id: UUID, _ serves: Bool) {
        var next = serving
        if serves { next.insert(id) } else { next.remove(id) }
        if next != serving { serving = next }
    }

    func library(_ host: UUID) -> RemoteDesignLibrary? {
        serving.contains(host) ? libraries[host] : nil
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
            RemoteDesignsModel.Host(id: host.id, name: host.name, listing: libraries[host.id]?.listing, state: host.state)
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
        guard let source = source(ref) else { return indexes[ref] }
        do {
            let index = try await source.sync()
            if indexes[ref] != index { indexes[ref] = index }
            if failures[ref] != nil { failures[ref] = nil }
            return index
        } catch {
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
        if on {
            watchers[ref, default: []].insert(token)
            observers[token] = observer
        } else {
            watchers[ref]?.remove(token)
            if watchers[ref]?.isEmpty == true { watchers[ref] = nil }
            observers[token] = nil
        }
        libraries[ref.host]?.watch(Set(watchers.keys.filter { $0.host == ref.host }.map(\.design)))
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
    func create(host: UUID, brief: String, spaceID: SpaceID, system: String?) async throws -> HostDesignRef {
        guard let library = library(host) else { throw MobileDesignsError.offline }
        guard case .created(let id, _) = try await library.request(.create(RemoteDesignCreate(brief: brief, spaceID: spaceID,
                                                                                               systemNamespace: system))) else {
            throw MobileDesignsError.unexpected
        }
        await list(host)
        return HostDesignRef(host: host, design: id)
    }

    // MARK: Lookups

    func design(_ ref: HostDesignRef) -> Design? {
        hosts.host(ref.host)?.state.designs.first { $0.id == ref.design }
            ?? libraries[ref.host]?.listing?.designs.first { $0.id == ref.design }?.design
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
        libraries[ref.host]?.listing?.designs.first { $0.id == ref.design }
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

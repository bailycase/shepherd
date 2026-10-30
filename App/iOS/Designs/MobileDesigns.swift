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
    /// The design deleted last, while its host holds it for Undo (the screenshot fixtures set it).
    var deleted: (ref: HostDesignRef, name: String, id: UUID)?
    /// Why the last design action failed, until dismissed.
    private(set) var problem: String?
    /// Moves when a host's systems change: a system's page reads its system again.
    private(set) var systemsRevision = 0

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
        // Another device changed a host's systems: the Designs screen and Design systems list them again.
        libraries.observeSystems("phone") { [weak self] host in
            guard let self else { return }
            self.swatches = self.swatches.filter { !$0.key.hasPrefix(host.uuidString + "/") }
            self.systemsRevision &+= 1
            Task { await self.list(host) }
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
        try await writeComment(ref) { .addComment(designID: ref.design, draft: draft, baseRevision: $0) }
    }

    func writeComment(_ ref: HostDesignRef, request: (UInt64?) -> RemoteDesignRequest) async throws -> DesignComment {
        guard let library = library(ref.host) else { throw MobileDesignsError.offline }
        let base = comments[ref]?.revision
        let result: RemoteDesignResult
        do {
            result = try await library.request(request(base))
        } catch RemoteHostClientError.rejected(let code, _) where code == "stale_revision" {
            // The comments moved on: read them again and pin it once more.
            await loadComments(ref)
            result = try await library.request(request(comments[ref]?.revision))
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

    // MARK: Lifecycle (design.agent.v1, design.lifecycle.v1, design.delete.v1, design.systems.v1)

    /// Whether `host` offers `capability` beside its designs.
    func supports(_ host: UUID, _ capability: String) -> Bool {
        library(host) != nil && hosts.host(host)?.supports(capability) == true
    }

    /// The design's agent: the one its host has, else one its host starts as its own Open does.
    func ensureAgent(_ ref: HostDesignRef) async throws -> AgentRef {
        if let agent = agent(ref) { return agent }
        guard let library = library(ref.host) else { throw MobileDesignsError.offline }
        guard case .agent(let id) = try await library.request(.ensureAgent(designID: ref.design)) else { throw MobileDesignsError.unexpected }
        return AgentRef(host: ref.host, agent: id)
    }

    func report(_ problem: String?) {
        if self.problem != problem { self.problem = problem }
    }

    /// Delete, then Undo over the Designs screen for the host's window (counted from here: the
    /// host's clock isn't this device's).
    func deleteWithUndo(_ ref: HostDesignRef, name: String) async throws {
        _ = try await delete(ref)
        let id = UUID()
        deleted = (ref, name, id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(DesignDeletion.undoWindow))
            if self?.deleted?.id == id { self?.deleted = nil }
        }
    }

    func undoLastDelete() async {
        guard let last = deleted else { return }
        deleted = nil
        do { try await undoDelete(last.ref) } catch {
            report("Couldn't bring back \(last.name): \(MobileDesignsError.words(error))")
        }
    }

    /// Rename: the design's canvas title through its host's canvas update, as the Mac's does.
    func rename(_ ref: HostDesignRef, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let library = library(ref.host) else { throw MobileDesignsError.offline }
        _ = try await library.request(.updateIndex(designID: ref.design, patch: .object(["title": .string(trimmed)]), baseRevision: nil))
        await list(ref.host)
    }

    /// Delete, as the host's own: until when Undo can bring it back.
    func delete(_ ref: HostDesignRef) async throws -> DesignDeletion {
        guard let library = library(ref.host) else { throw MobileDesignsError.offline }
        guard case .deleted(let deletion) = try await library.request(.delete(designID: ref.design)) else { throw MobileDesignsError.unexpected }
        await list(ref.host)
        return deletion
    }

    func undoDelete(_ ref: HostDesignRef) async throws {
        guard let library = library(ref.host) else { throw MobileDesignsError.offline }
        _ = try await library.request(.undoDelete(designID: ref.design))
        await list(ref.host)
    }

    /// "Build one from a repo" in one of `host`'s spaces: the build's agent there.
    func buildSystem(host: UUID, space: SpaceID) async throws -> AgentRef? {
        guard let library = library(host) else { throw MobileDesignsError.offline }
        guard case .created(_, let agent) = try await library.request(.buildSystem(spaceID: space)) else { throw MobileDesignsError.unexpected }
        await list(host)
        return agent.map { AgentRef(host: host, agent: $0) }
    }

    /// Each serving host's system builds still reading their space (their agent hasn't written a
    /// system yet), for Design systems' Building section.
    var builds: [(host: UUID, hostName: String, build: Design, space: String?)] {
        hosts.hosts.filter { serving.contains($0.id) }.flatMap { host -> [(host: UUID, hostName: String, build: Design, space: String?)] in
            let built = Set(library(host.id)?.listing?.systems.compactMap(\.info.ownerDesignID) ?? [])
            return host.state.designs.filter { $0.buildsSystem && !built.contains($0.id) }.map { build in
                (host.id, host.name, build, build.sourceSpaceID.flatMap { id in host.state.spaces.first { $0.id == id }?.name })
            }
        }
    }

    /// A build's agent there, while it has one.
    func buildAgent(host: UUID, build: DesignID) -> AgentRef? {
        guard let state = hosts.host(host)?.state, let design = state.designs.first(where: { $0.id == build }) else { return nil }
        let agent = state.agents.first { $0.id == design.agentID } ?? state.agents.first { $0.designID == build }
        return agent.map { AgentRef(host: host, agent: $0.id) }
    }

    /// The spaces of each host that builds systems for other devices (`design.systems.v1`).
    var buildableSpaces: [(host: UUID, name: String, spaces: [Space])] {
        hosts.hosts.filter { supports($0.id, RemoteProtocol.designSystemsCapability) }.map { host in
            (host.id, host.name, host.state.spaces.filter { !$0.holdsDesigns && !$0.holdsProjects })
        }.filter { !$0.spaces.isEmpty }
    }

    /// A Claude Design ZIP from Files, imported on `host` (`design.import.v1`); answers the design.
    func importProject(host: UUID, url: URL, progress: @escaping (Double) -> Void) async throws -> HostDesignRef {
        guard let library = library(host) else { throw MobileDesignsError.offline }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let (design, _) = try await library.importProject(file: url, progress: progress)
        await list(host)
        return HostDesignRef(host: host, design: design)
    }

    /// Duplicate on the host; answers the copy.
    func duplicate(_ ref: HostDesignRef) async throws -> HostDesignRef {
        guard let library = library(ref.host) else { throw MobileDesignsError.offline }
        guard case .designDuplicated(let copy) = try await library.request(.duplicate(designID: ref.design)) else {
            throw MobileDesignsError.unexpected
        }
        await list(ref.host)
        return HostDesignRef(host: ref.host, design: copy.id)
    }

    func removeFromRecents(_ ref: HostDesignRef) async throws {
        guard let library = library(ref.host) else { throw MobileDesignsError.offline }
        _ = try await library.request(.removeFromRecents(designID: ref.design))
    }

    /// A design system change on its host (rename, duplicate, delete, re-sync), then the
    /// systems listed again. Answers the system it left, if one.
    @discardableResult
    func changeSystem(host: UUID, _ request: RemoteDesignRequest) async throws -> DesignSystemSummary? {
        guard let library = library(host) else { throw MobileDesignsError.offline }
        let result = try await library.request(request)
        library.systemsChanged()
        await list(host)
        switch result {
        case .systemChanged(let summary): return summary
        case .systemSynced(let synced): return synced.summary
        default: return nil
        }
    }

    // MARK: References (design.references.v1)

    /// A piece of `host`'s design pinned by the host (named `local`, as the host sees it).
    func pinReference(host: UUID, _ reference: DesignReference) async throws -> RemoteDesignReferencePin {
        guard let library = library(host) else { throw MobileDesignsError.offline }
        guard case .referencePinned(let pin) = try await library.request(.pinReference(reference)) else { throw MobileDesignsError.unexpected }
        return pin
    }

    /// A pasted or picked reference for a thread on `host`, named as that host sees it: one this
    /// device copied names the host (`remote(host)`), one from the host's own thread `local`; one
    /// naming any other Mac is refused (that host can't read it).
    static func onHost(_ reference: DesignReference, host: UUID) throws -> DesignReference {
        switch reference.host {
        case .local: return reference
        case .remote(let id) where id == host: return reference.onHost(host) ?? reference
        case .remote: throw RemoteHostClientError.rejected(code: "remote_design", message: RemoteHostClient.designReferencesRefusal)
        }
    }

    /// Pins a reference and puts it beside the draft of a thread on that host.
    func attachReference(_ reference: DesignReference, to store: NativeThreadStore, host: UUID) async throws {
        let pin = try await pinReference(host: host, try Self.onHost(reference, host: host))
        let attached = NativeAttachedReference(reference: pin.reference, label: pin.label ?? DesignReferencePresentation.crumbs(
            DesignReferenceRecord(ref: pin.reference.string, design: pin.design, boardTitle: pin.boardTitle)).joined(separator: " › "),
                                               outline: pin.outline)
        guard store.attach(reference: attached) else {
            throw RemoteHostClientError.rejected(code: "too_many", message: "A message carries at most \(DesignReferenceRecord.maxPerMessage) design references.")
        }
    }

    /// The host's ordinary threads a piece can go to: never a design's agent, a Project's
    /// coordinator or worker, most recently active first.
    func referenceThreads(host: UUID) -> [Agent] {
        guard let state = hosts.host(host)?.state else { return [] }
        let workers = state.projectWorkerIDs
        return state.agents.filter { state.isSidebarThread($0, workers: workers) && $0.designID == nil }
            .sorted { ($0.lastActiveAt ?? -1) > ($1.lastActiveAt ?? -1) }
    }

    /// Implement in a thread…: `references` (pinned, `local`) and `text` to one of the host's
    /// threads now, waiting while its pi starts.
    func sendReferences(_ references: [NativeAttachedReference], text: String, to agent: AgentRef) async throws {
        guard let client = hosts.host(agent.host)?.connectedClient else { throw MobileDesignsError.offline }
        try await NativeReferenceSend.send(references, text: text) { try await client.nativeThread(agentID: agent.agent, request: $0) }
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

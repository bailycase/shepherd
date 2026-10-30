import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

/// One host's designs as a client shows them (the Mac's Designs page, the iPhone's and iPad's
/// Designs): the host's listing, each design's files (`RemoteDesignSource`, over the shared
/// cache), and the designs on screen, which the host pushes changes for. Nothing is shown for a
/// host that doesn't offer `designs.v1` (an older Shepherd, or its Design tool off).
@MainActor
@Observable
public final class RemoteDesignLibrary {
    public let hostID: UUID
    /// The host's designs and systems as last listed; nil until listed.
    public private(set) var listing: RemoteDesignListing?
    /// Why the last listing failed; nil once one succeeds.
    public private(set) var error: String?
    /// The host offers designs now.
    public private(set) var available = false

    /// A watched design changed on the host: its files (a revision), its comments, or both.
    @ObservationIgnored public var onDesignChanged: ((DesignID, UInt64?, UInt64?) -> Void)?

    @ObservationIgnored public let cache: RemoteDesignCache
    /// The connection, readable from the renderer's threads too.
    @ObservationIgnored private let link = RemoteDesignLink()
    private var transport: (any RemoteDesignTransport)? { link.transport }
    @ObservationIgnored private var sources: [DesignID: RemoteDesignSource] = [:]
    @ObservationIgnored private var watched: Set<DesignID> = []
    @ObservationIgnored private var systemReads: [String: DesignSystemRead] = [:]
    /// The @ picker's rows of each design opened in it: its pages, boards and elements, read from
    /// the files this device synced, at the revision they were read.
    @ObservationIgnored private var mentionEntries: [DesignID: DesignMentionEntries] = [:]
    /// Moves when a design's rows were read for the @ picker.
    public private(set) var mentionsRevision = 0
    /// Moves each time the host's systems change: pages that show one read it again.
    public private(set) var systemsRevision = 0

    public init(hostID: UUID, cache: RemoteDesignCache) {
        self.hostID = hostID
        self.cache = cache
    }

    public func forget() {
        cache.forget(host: hostID)
        link.transport = nil
        available = false
        listing = nil
        error = nil
        watched = []
        systemReads = [:]
        mentionEntries = [:]
        for source in sources.values { source.invalidate() }
        sources = [:]
        onDesignChanged = nil
    }

    /// The host's connection changed: `transport` while it is connected and offers designs, nil
    /// otherwise. A new connection is told again which designs are on screen.
    public func connect(_ transport: (any RemoteDesignTransport)?, available: Bool) {
        guard !cache.isForgotten(host: hostID) else { return }
        link.transport = available ? transport : nil
        if self.available != available { self.available = available }
        if !available {
            if listing != nil { listing = nil }
            return
        }
        if !watched.isEmpty { sendWatch() }
    }

    /// Lists the host's designs again.
    public func refresh() async {
        guard transport != nil else { return }
        do {
            guard case .listing(let next) = try await request(.list) else { return }
            if listing != next { listing = next }
            if error != nil { error = nil }
            let live = Set(next.designs.map(\.id))
            for id in Set(sources.keys).subtracting(live) {
                sources.removeValue(forKey: id)
                cache.remove(RemoteDesignCache.Key(host: hostID, design: id))
            }
        } catch {
            guard !cache.isForgotten(host: hostID) else { return }
            self.error = "\(error)"
        }
    }

    /// A design's files, made on first use.
    public func source(_ id: DesignID) -> RemoteDesignSource {
        if let source = sources[id] { return source }
        let link = link
        let source = RemoteDesignSource(key: RemoteDesignCache.Key(host: hostID, design: id), cache: cache) { link.transport }
        if !cache.isForgotten(host: hostID) { sources[id] = source }
        return source
    }

    /// The designs on screen: the host pushes changes for these alone.
    public func watch(_ ids: Set<DesignID>) {
        guard !cache.isForgotten(host: hostID) else { return }
        guard ids != watched else { return }
        watched = ids
        sendWatch()
    }

    /// The host pushed a change to a watched design.
    public func changed(_ id: DesignID, revision: UInt64?, commentsRevision: UInt64?) {
        onDesignChanged?(id, revision, commentsRevision)
    }

    /// The host's design systems changed (`designSystemsChanged`): its systems are read again, and
    /// the listing that names them.
    public func systemsChanged() {
        systemReads = [:]
        systemsRevision &+= 1
        Task { await refresh() }
    }

    /// A design system whole, as the host last answered it (`system`), read on first use.
    public func system(_ namespace: String) async throws -> DesignSystemRead {
        if let read = systemReads[namespace] { return read }
        guard case .system(let read) = try await request(.system(namespace: namespace)) else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected design reply")
        }
        systemReads[namespace] = read
        return read
    }

    /// Every file of a design system its page draws specimens from, fetched in pieces
    /// (`design.systems.v1`); a file the host no longer has is left out.
    public func systemFiles(_ namespace: String) async throws -> [String: Data] {
        let read = try await system(namespace)
        var files: [String: Data] = [:]
        for path in read.files {
            var data = Data()
            var total = Int.max
            while data.count < total {
                guard case .chunk(let piece) = try await request(.systemFile(namespace: namespace, path: path, offset: data.count)),
                      piece.offset == data.count, piece.total <= DesignImport.maxFileBytes else { break }
                total = piece.total
                data.append(piece.data)
                if piece.data.isEmpty { break }
            }
            if data.count == total { files[path] = data }
        }
        return files
    }

    /// Uploads a Claude Design project's ZIP at `file` and has the host import it
    /// (`design.import.v1`), read and sent a piece at a time, in order; `progress` hears the share
    /// sent. A failure or cancellation leaves nothing on the host. Answers the design and its agent
    /// there. The caller holds any security scope `file` needs for the whole call.
    public func importProject(file: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> (DesignID, AgentID?) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard case .importStarted(let upload) = try await request(.importBegin(name: file.lastPathComponent, size: size)) else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected design reply")
        }
        do {
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                guard let piece = try handle.read(upToCount: min(RemoteProtocol.designChunkBytes, size - offset)), !piece.isEmpty else {
                    throw RemoteHostClientError.rejected(code: "import_failed", message: "\(file.lastPathComponent) changed while it was sent.")
                }
                _ = try await request(.importChunk(uploadID: upload, offset: offset, data: piece))
                offset += piece.count
                progress(Double(offset) / Double(size))
            }
            guard case .created(let design, let agent) = try await request(.importFinish(uploadID: upload)) else {
                throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected design reply")
            }
            Task { await refresh() }
            return (design, agent)
        } catch {
            _ = try? await request(.importCancel(uploadID: upload))
            throw error
        }
    }

    /// The picture of a reference a thread was sent, read in pieces from the host's kept copy
    /// (`referencePicture`): at most `DesignImport.maxFileBytes`, checked against its hash.
    public func referencePicture(agentID: AgentID, payloadID: UUID) async throws -> Data {
        var data = Data()
        var expected: (sha: String, total: Int)?
        repeat {
            guard case .chunk(let piece) = try await request(.referencePicture(agentID: agentID, payloadID: payloadID, offset: data.count)),
                  piece.offset == data.count, piece.total <= DesignImport.maxFileBytes,
                  expected.map({ $0 == (piece.sha256, piece.total) }) ?? true,
                  !piece.data.isEmpty || piece.total == 0 else {
                throw RemoteHostClientError.rejected(code: "corrupt", message: "The picture didn't arrive whole.")
            }
            expected = (piece.sha256, piece.total)
            data.append(piece.data)
        } while data.count < expected!.total
        guard RemoteDesignCache.sha256(data) == expected?.sha else {
            throw RemoteHostClientError.rejected(code: "corrupt", message: "The picture didn't arrive whole.")
        }
        return data
    }

    // MARK: The @ picker (design.references.v1)

    /// What a host thread's @ picker lists: the host's designs as listed (references named as the
    /// host sees them, `local`), and each design's pages, boards and elements once it was opened
    /// in the picker (`openMentions`).
    // ponytail: an unopened design's boards are found by its name alone; a host-side catalog if searching them matters.
    public func mentionCatalog() -> DesignMentionCatalog {
        var catalog = DesignMentionCatalog()
        for summary in listing?.designs ?? [] {
            let design = summary.design
            if let entries = mentionEntries[design.id] {
                catalog.designs.append(entries.design)
                catalog.pages[design.id] = entries.pages
                catalog.boards[design.id] = entries.boards
                catalog.elements.merge(entries.elements) { $1 }
            } else if let whole = DesignReference(designID: design.id) {
                catalog.designs.append(DesignMentionItem(kind: .design, reference: whole, title: design.name, breadcrumb: [],
                                                         system: design.systemNamespace, boardCount: summary.boardCount,
                                                         activeAt: design.lastActiveAt, revision: summary.revision))
            }
        }
        return catalog
    }

    /// The picker opened a design: its files synced and its rows read from them, once per revision.
    public func openMentions(_ id: DesignID) async {
        let source = source(id)
        guard let index = try? await source.sync(), let design = listing?.designs.first(where: { $0.id == id })?.design,
              mentionEntries[id]?.design.revision != index.snapshot.revision else { return }
        var sources: [DesignPath: String] = [:]
        for path in index.snapshot.index.boards.keys { sources[path] = try? await source.source(path) }
        guard let entries = DesignMentionCatalog.entries(design: design, snapshot: index.snapshot, sources: sources,
                                                         system: design.systemNamespace) else { return }
        mentionEntries[id] = entries
        mentionsRevision &+= 1
    }

    /// Asks the host whatever `request` asks, through its connection now.
    public func request(_ request: RemoteDesignRequest) async throws -> RemoteDesignResult {
        guard !cache.isForgotten(host: hostID), let transport else { throw RemoteHostClientError.rejected(code: "update_required", message: RemoteHostClient.designsRefusal) }
        let result = try await transport.design(request)
        guard !cache.isForgotten(host: hostID) else { throw CancellationError() }
        return result
    }

    private func sendWatch() {
        guard transport != nil else { return }
        let ids = watched.sorted { $0.rawValue < $1.rawValue }
        Task { _ = try? await request(.watch(designIDs: ids)) }
    }
}

/// A host's connection as its design sources reach it, from any thread.
final class RemoteDesignLink: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any RemoteDesignTransport)?

    var transport: (any RemoteDesignTransport)? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

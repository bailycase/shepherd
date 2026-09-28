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

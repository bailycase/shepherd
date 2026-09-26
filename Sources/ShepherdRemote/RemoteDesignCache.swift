import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol

/// What a remote design's files are fetched through: a host connection's design requests
/// (`RemoteHostClient`), or a test's stand-in.
public protocol RemoteDesignTransport: AnyObject, Sendable {
    func design(_ request: RemoteDesignRequest) async throws -> RemoteDesignResult
}

extension RemoteHostClient: RemoteDesignTransport {}

/// The files of remote hosts' designs as this device last fetched them, by host and design: each
/// file's bytes kept by its SHA-256, which paths of the design name which hash, uploads by id,
/// and the downloads still under way (so a dropped connection resumes where it stopped).
/// Bytes are checked against their hash before they are kept.
///
/// Held in memory within `memoryBudget`, the designs used least recently given up first; with a
/// `directory`, files are also written there (`<host>/<design>/<sha>`) and read back when memory
/// no longer holds them. Thread-safe.
public final class RemoteDesignCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var host: UUID
        public var design: DesignID

        public init(host: UUID, design: DesignID) {
            self.host = host
            self.design = design
        }
    }

    /// An upload as kept: its file name (`<id>.<ext>`) and bytes.
    public struct Asset: Sendable, Equatable {
        public var name: String
        public var data: Data
    }

    /// A download under way: the file's hash (when known up front), size, and the bytes so far.
    public struct Partial: Sendable, Equatable {
        public var sha256: String
        public var total: Int
        public var data: Data
    }

    private struct Entry {
        var paths: [String: String] = [:]
        var objects: [String: Data] = [:]
        var assets: [String: Asset] = [:]
        var partials: [String: Partial] = [:]
        var lastUsed: UInt64 = 0

        var bytes: Int {
            objects.values.reduce(0) { $0 + $1.count } + assets.values.reduce(0) { $0 + $1.data.count }
                + partials.values.reduce(0) { $0 + $1.data.count }
        }
    }

    public let directory: URL?
    public let memoryBudget: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    public init(directory: URL? = nil, memoryBudget: Int = 96 * 1024 * 1024) {
        self.directory = directory
        self.memoryBudget = memoryBudget
    }

    // MARK: Files by hash

    /// The bytes kept for `sha256` in the design, from memory or disk.
    public func object(_ key: Key, sha256: String) -> Data? {
        if let data = locked({ touch(key)?.objects[sha256] }) { return data }
        guard let url = fileURL(key, sha256), let data = try? Data(contentsOf: url), Self.sha256(data) == sha256 else { return nil }
        locked { entries[key, default: Entry()].objects[sha256] = data }
        trim(keeping: key)
        return data
    }

    /// Keeps `data` under its hash; false (and nothing kept) when it doesn't hash to `sha256`.
    @discardableResult
    public func store(_ data: Data, sha256: String, in key: Key) -> Bool {
        guard Self.sha256(data) == sha256 else { return false }
        locked {
            touch(key, create: true)
            entries[key]?.objects[sha256] = data
        }
        if let url = fileURL(key, sha256) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        trim(keeping: key)
        return true
    }

    /// Which hash each path of the design names, as last synced.
    public func paths(_ key: Key) -> [String: String] {
        locked { entries[key]?.paths ?? [:] }
    }

    /// Records which hash each path names now, and gives up kept files no path names any more.
    public func setPaths(_ paths: [String: String], for key: Key) {
        let referenced = Set(paths.values)
        let dropped: [String] = locked {
            touch(key, create: true)
            entries[key]?.paths = paths
            let gone = entries[key]?.objects.keys.filter { !referenced.contains($0) } ?? []
            for sha in gone { entries[key]?.objects.removeValue(forKey: sha) }
            return Array(gone)
        }
        for sha in dropped { if let url = fileURL(key, sha) { try? FileManager.default.removeItem(at: url) } }
    }

    /// A path's bytes as last synced, when they are still kept.
    public func file(_ key: Key, path: String) -> Data? {
        guard let sha = paths(key)[path] else { return nil }
        return object(key, sha256: sha)
    }

    // MARK: Uploads

    public func asset(_ key: Key, id: String) -> Asset? {
        locked { touch(key)?.assets[id] }
    }

    public func storeAsset(_ asset: Asset, id: String, in key: Key) {
        locked {
            touch(key, create: true)
            entries[key]?.assets[id] = asset
            entries[key]?.partials.removeValue(forKey: "asset:" + id)
        }
        trim(keeping: key)
    }

    // MARK: Downloads under way

    /// The download named `name` in the design (`asset:<id>`, `file:<path>`), if one stopped
    /// part way.
    public func partial(_ key: Key, _ name: String) -> Partial? {
        locked { entries[key]?.partials[name] }
    }

    public func setPartial(_ partial: Partial?, _ name: String, in key: Key) {
        locked {
            touch(key, create: true)
            entries[key]?.partials[name] = partial
        }
    }

    // MARK: Whole designs

    /// Forgets a design (it is gone from its host).
    public func remove(_ key: Key) {
        locked { _ = entries.removeValue(forKey: key) }
        if let directory { try? FileManager.default.removeItem(at: Self.folder(directory, key)) }
    }

    /// Bytes held in memory now.
    public var memoryBytes: Int { locked { entries.values.reduce(0) { $0 + $1.bytes } } }

    /// Gives up the designs used least recently until memory fits the budget, never `key`. Their
    /// files stay on disk where there is a directory.
    private func trim(keeping key: Key) {
        locked {
            var total = entries.values.reduce(0) { $0 + $1.bytes }
            guard total > memoryBudget else { return }
            for (other, entry) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where other != key {
                total -= entry.bytes
                // The path map stays: it is small, and what it names is on disk or fetched again.
                entries[other] = Entry(paths: entry.paths, lastUsed: entry.lastUsed)
                if total <= memoryBudget { break }
            }
        }
    }

    @discardableResult
    private func touch(_ key: Key, create: Bool = false) -> Entry? {
        clock += 1
        if entries[key] == nil {
            guard create else { return nil }
            entries[key] = Entry()
        }
        entries[key]?.lastUsed = clock
        return entries[key]
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func fileURL(_ key: Key, _ sha256: String) -> URL? {
        guard let directory, sha256.count == 64, sha256.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        return Self.folder(directory, key).appendingPathComponent(sha256)
    }

    private static func folder(_ directory: URL, _ key: Key) -> URL {
        // A design id names a folder only by its own grammar; anything else is hashed.
        let raw = key.design.rawValue
        let safe = !raw.isEmpty && raw.count <= 64 && raw.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_")
        }
        return directory.appendingPathComponent(key.host.uuidString, isDirectory: true)
            .appendingPathComponent(safe ? raw : sha256(Data(raw.utf8)), isDirectory: true)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One remote design's files for its canvas: synced from the host by hash (only what changed
/// travels), served to the board renderer from the cache (`DesignFileSource`), and uploads
/// downloaded in pieces on first use, resuming where a dropped connection stopped.
public final class RemoteDesignSource: DesignFileSource, @unchecked Sendable {
    public let key: RemoteDesignCache.Key
    public let cache: RemoteDesignCache
    private let transport: @Sendable () -> (any RemoteDesignTransport)?
    private let lock = NSLock()
    private var lastIndex: RemoteDesignIndex?

    /// `transport` is asked each time: the host's connection now, or nil while it is away (the
    /// cache still serves what it has).
    public init(key: RemoteDesignCache.Key, cache: RemoteDesignCache, transport: @escaping @Sendable () -> (any RemoteDesignTransport)?) {
        self.key = key
        self.cache = cache
        self.transport = transport
    }

    /// The index as last synced.
    public var index: RemoteDesignIndex? {
        lock.lock()
        defer { lock.unlock() }
        return lastIndex
    }

    /// Reads the design's index and fetches every file whose hash this device doesn't hold:
    /// several small files to a reply, a large one in pieces. Answers the index.
    @discardableResult
    public func sync() async throws -> RemoteDesignIndex {
        do {
            return try await syncOnce()
        } catch RemoteHostClientError.rejected(let code, _) where code == RemoteDesignCode.staleFile {
            // A file changed between the index and its fetch: read the design again, once.
            return try await syncOnce()
        }
    }

    private func syncOnce() async throws -> RemoteDesignIndex {
        let transport = try requireTransport()
        guard case .index(let index) = try await transport.design(.index(designID: key.design)) else { throw Self.unexpected }
        var paths = Dictionary(index.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        var remaining = index.files.filter { cache.object(key, sha256: $0.sha256) == nil }.map(\.path)
        while !remaining.isEmpty {
            guard case .files(let reply) = try await transport.design(.boards(designID: key.design, paths: remaining, knownShas: [:])) else {
                throw Self.unexpected
            }
            var next: [String] = []
            for file in reply.changed {
                paths[file.path] = file.sha256
                if let data = file.data {
                    cache.store(data, sha256: file.sha256, in: key)
                } else if file.size > RemoteProtocol.designChunkBytes {
                    try await fetchInPieces(file.path, sha256: file.sha256, transport: transport)
                } else {
                    next.append(file.path)
                }
            }
            for path in reply.missing { paths.removeValue(forKey: path) }
            // Every round keeps at least the first file that fits; one that didn't come back
            // inline after that is fetched in pieces.
            if next.count == remaining.count {
                for path in next { if let sha = paths[path] { try await fetchInPieces(path, sha256: sha, transport: transport) } }
                next = []
            }
            remaining = next
        }
        cache.setPaths(paths, for: key)
        remember(index)
        return index
    }

    /// A board's source, from the cache, fetching it when it isn't there.
    public func source(_ path: DesignPath) async throws -> String {
        guard let data = await projectFile(path.rawValue) else { throw RemoteHostClientError.rejected(code: "no_such_board", message: "no board at \(path)") }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: DesignFileSource

    public func projectFile(_ path: String) async -> Data? {
        if let data = cache.file(key, path: path) { return data }
        guard let transport = transport(),
              case .files(let reply) = try? await transport.design(.boards(designID: key.design, paths: [path], knownShas: [:])),
              let file = reply.changed.first(where: { $0.path == path }) else { return nil }
        if let data = file.data {
            guard cache.store(data, sha256: file.sha256, in: key) else { return nil }
        } else {
            guard (try? await fetchInPieces(path, sha256: file.sha256, transport: transport)) != nil else { return nil }
        }
        var paths = cache.paths(key)
        paths[path] = file.sha256
        cache.setPaths(paths, for: key)
        return cache.object(key, sha256: file.sha256)
    }

    public func blob(_ id: String) async -> (name: String, data: Data)? {
        if let asset = cache.asset(key, id: id) { return (asset.name, asset.data) }
        guard let transport = transport() else { return nil }
        return try? await downloadAsset(id, transport: transport)
    }

    /// Downloads an upload in pieces, from where an earlier try stopped.
    public func downloadAsset(_ id: String, transport: any RemoteDesignTransport) async throws -> (name: String, data: Data) {
        let name = "asset:" + id
        var partial = cache.partial(key, name)
        var fileName: String?
        while true {
            let offset = partial?.data.count ?? 0
            guard case .chunk(let chunk) = try await transport.design(.asset(designID: key.design, blobID: id, offset: offset)) else {
                throw Self.unexpected
            }
            // The upload changed since the earlier try: start again.
            if let known = partial, known.sha256 != chunk.sha256 || known.total != chunk.total {
                cache.setPartial(nil, name, in: key)
                partial = nil
                continue
            }
            fileName = chunk.name ?? fileName
            var next = partial ?? RemoteDesignCache.Partial(sha256: chunk.sha256, total: chunk.total, data: Data())
            guard chunk.offset == next.data.count, Self.fits(chunk, into: next) else { throw Self.unexpected }
            next.data.append(chunk.data)
            partial = next
            cache.setPartial(next, name, in: key)
            if chunk.isLast || chunk.data.isEmpty { break }
        }
        guard let done = partial, done.data.count == done.total, RemoteDesignCache.sha256(done.data) == done.sha256 else {
            cache.setPartial(nil, name, in: key)
            throw RemoteHostClientError.rejected(code: "corrupt", message: "The upload \(id) didn't arrive whole.")
        }
        let asset = RemoteDesignCache.Asset(name: fileName ?? id, data: done.data)
        cache.storeAsset(asset, id: id, in: key)
        return (asset.name, asset.data)
    }

    /// Fetches one file in pieces, from where an earlier try stopped, and keeps it.
    private func fetchInPieces(_ path: String, sha256: String, transport: any RemoteDesignTransport) async throws {
        let name = "file:" + path
        var partial = cache.partial(key, name).flatMap { $0.sha256 == sha256 ? $0 : nil }
        while true {
            let offset = partial?.data.count ?? 0
            guard case .chunk(let chunk) = try await transport.design(.file(designID: key.design, path: path, sha256: sha256, offset: offset)),
                  chunk.offset == offset else { throw Self.unexpected }
            var next = partial ?? RemoteDesignCache.Partial(sha256: sha256, total: chunk.total, data: Data())
            guard Self.fits(chunk, into: next) else {
                cache.setPartial(nil, name, in: key)
                throw Self.unexpected
            }
            next.data.append(chunk.data)
            partial = next
            cache.setPartial(next, name, in: key)
            if chunk.isLast || chunk.data.isEmpty { break }
        }
        cache.setPartial(nil, name, in: key)
        guard let data = partial?.data, cache.store(data, sha256: sha256, in: key) else {
            throw RemoteHostClientError.rejected(code: "corrupt", message: "\(path) didn't arrive whole.")
        }
    }

    private func remember(_ index: RemoteDesignIndex) {
        lock.lock()
        defer { lock.unlock() }
        lastIndex = index
    }

    private func requireTransport() throws -> any RemoteDesignTransport {
        guard let transport = transport() else { throw RemoteHostClientError.disconnected }
        return transport
    }

    /// A piece that keeps the download within the size it began with and the file cap: a host
    /// never makes this device hold more than one file's worth.
    private static func fits(_ chunk: RemoteDesignChunk, into partial: RemoteDesignCache.Partial) -> Bool {
        chunk.total == partial.total && partial.total <= DesignImport.maxFileBytes && partial.data.count + chunk.data.count <= partial.total
    }

    static let unexpected = RemoteHostClientError.rejected(code: "protocol", message: "unexpected design reply")
}

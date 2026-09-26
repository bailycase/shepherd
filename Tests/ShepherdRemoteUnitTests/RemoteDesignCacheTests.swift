import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote
import ShepherdTestKit

/// A host's design as a stand-in transport serves it: its files by path, its uploads, and every
/// request it was asked. It answers as the host does (changed files only, inline up to a chunk).
private final class FakeDesignHost: RemoteDesignTransport, @unchecked Sendable {
    let design = DesignID(rawValue: "design-1")
    private let lock = NSLock()
    private var files: [String: Data]
    private var assets: [String: (name: String, data: Data)]
    private(set) var requests: [RemoteDesignRequest] = []
    /// Fails the next asset request after this many succeeded.
    var failAssetAfter: Int?

    init(files: [String: Data], assets: [String: (name: String, data: Data)] = [:]) {
        self.files = files
        self.assets = assets
    }

    func set(_ path: String, _ data: Data) {
        lock.lock(); files[path] = data; lock.unlock()
    }

    var asked: [RemoteDesignRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    func design(_ request: RemoteDesignRequest) async throws -> RemoteDesignResult {
        try answer(request)
    }

    private func answer(_ request: RemoteDesignRequest) throws -> RemoteDesignResult {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let sha = RemoteDesignCache.sha256
        switch request {
        case .index:
            let infos = files.keys.sorted().map { RemoteDesignFileInfo(path: $0, sha256: sha(files[$0]!), size: files[$0]!.count) }
            let snapshot = DesignSnapshot(designID: design, revision: 1, index: DesignIndex(title: "t"), boards: [:])
            return .index(RemoteDesignIndex(snapshot: snapshot, files: infos))
        case .boards(_, let paths, let known):
            var budget = RemoteProtocol.designChunkBytes
            var changed: [RemoteDesignFile] = []
            var missing: [String] = []
            for path in paths ?? files.keys.sorted() {
                guard let data = files[path] else { missing.append(path); continue }
                guard known[path] != sha(data) else { continue }
                let inline = data.count <= budget
                if inline { budget -= data.count }
                changed.append(RemoteDesignFile(path: path, sha256: sha(data), size: data.count, data: inline ? data : nil))
            }
            return .files(RemoteDesignFiles(designID: design, revision: 1, changed: changed, unchanged: [], missing: missing))
        case .file(_, let path, let expected, let offset):
            guard let data = files[path], sha(data) == expected else {
                throw RemoteHostClientError.rejected(code: RemoteDesignCode.staleFile, message: "moved")
            }
            let end = min(data.count, offset + RemoteProtocol.designChunkBytes)
            return .chunk(RemoteDesignChunk(sha256: expected, offset: offset, total: data.count, data: data.subdata(in: offset..<end)))
        case .asset(_, let id, let offset):
            if let limit = failAssetAfter {
                if limit == 0 { failAssetAfter = nil; throw RemoteHostClientError.disconnected }
                failAssetAfter = limit - 1
            }
            guard let asset = assets[id] else { throw RemoteHostClientError.rejected(code: RemoteDesignCode.noSuchFile, message: id) }
            let end = min(asset.data.count, offset + RemoteProtocol.designChunkBytes)
            return .chunk(RemoteDesignChunk(name: asset.name, sha256: sha(asset.data), offset: offset, total: asset.data.count,
                                            data: asset.data.subdata(in: offset..<end)))
        default:
            return .ok
        }
    }
}

@Suite("Remote design cache")
struct RemoteDesignCacheTests {
    static let host = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    static func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(seed)) })
    }

    private func source(_ fake: FakeDesignHost, cache: RemoteDesignCache = RemoteDesignCache()) -> RemoteDesignSource {
        RemoteDesignSource(key: RemoteDesignCache.Key(host: Self.host, design: fake.design), cache: cache) { fake }
    }

    private func fetched(_ requests: [RemoteDesignRequest]) -> [String] {
        requests.flatMap { request -> [String] in
            switch request {
            case .boards(_, let paths, _): paths ?? []
            case .file(_, let path, _, let offset): ["\(path)@\(offset)"]
            default: []
            }
        }
    }

    @Test func aSecondSyncFetchesOnlyWhatChanged() async throws {
        let fake = FakeDesignHost(files: ["A.dc.html": Data("<x-dc>A</x-dc>".utf8), "B.dc.html": Data("<x-dc>B</x-dc>".utf8),
                                         "styles/app.css": Data(":root{}".utf8)])
        let files = source(fake)

        try await files.sync()
        #expect(Set(fetched(fake.asked)) == ["A.dc.html", "B.dc.html", "styles/app.css"])
        #expect(await files.projectFile("styles/app.css") == Data(":root{}".utf8))

        let before = fake.asked.count
        try await files.sync()
        #expect(fetched(Array(fake.asked.dropFirst(before))).isEmpty, "nothing moved: only the index is read")

        fake.set("B.dc.html", Data("<x-dc>B2</x-dc>".utf8))
        let again = fake.asked.count
        try await files.sync()
        #expect(fetched(Array(fake.asked.dropFirst(again))) == ["B.dc.html"])
        #expect(try await files.source(DesignPath("B.dc.html")!) == "<x-dc>B2</x-dc>")
    }

    /// Several small files come in one reply until a chunk is full; the rest follow in the next.
    @Test func manyBoardsComeAFewToAReply() async throws {
        let size = RemoteProtocol.designChunkBytes / 3 + 1
        var files: [String: Data] = [:]
        for (index, name) in ["A", "B", "C", "D", "E"].enumerated() { files["\(name).dc.html"] = Self.bytes(size, seed: UInt8(index)) }
        let fake = FakeDesignHost(files: files)
        let design = source(fake)

        try await design.sync()
        let rounds = fake.asked.filter { if case .boards = $0 { true } else { false } }
        #expect(rounds.count == 3, "two to a reply: 2 + 2 + 1")
        for (path, data) in files { #expect(await design.projectFile(path) == data) }
    }

    @Test func aFileLargerThanAChunkArrivesInPieces() async throws {
        let font = Self.bytes(RemoteProtocol.designChunkBytes * 2 + 5)
        let fake = FakeDesignHost(files: ["fonts/Inter.woff2": font])
        let files = source(fake)

        try await files.sync()
        let pieces = fetched(fake.asked).filter { $0.hasPrefix("fonts/Inter.woff2@") }
        #expect(pieces == ["fonts/Inter.woff2@0", "fonts/Inter.woff2@262144", "fonts/Inter.woff2@524288"])
        #expect(await files.projectFile("fonts/Inter.woff2") == font)
    }

    @Test func anUploadResumesWhereADroppedConnectionStopped() async throws {
        let image = Self.bytes(RemoteProtocol.designChunkBytes * 2 + 100)
        let fake = FakeDesignHost(files: [:], assets: ["3f2a91c0": ("3f2a91c0.png", image)])
        fake.failAssetAfter = 1
        let cache = RemoteDesignCache()
        let files = source(fake, cache: cache)

        await #expect(throws: RemoteHostClientError.self) { try await files.downloadAsset("3f2a91c0", transport: fake) }
        #expect(cache.partial(files.key, "asset:3f2a91c0")?.data.count == RemoteProtocol.designChunkBytes)

        let blob = try #require(await files.blob("3f2a91c0"))
        #expect(blob.name == "3f2a91c0.png" && blob.data == image)
        let offsets = fake.asked.compactMap { if case .asset(_, _, let offset) = $0 { offset } else { nil } }
        #expect(offsets == [0, 262_144, 262_144, 524_288], "the second try starts at the first piece's end")
        #expect(cache.partial(files.key, "asset:3f2a91c0") == nil)
        let before = fake.asked.count
        #expect(await files.blob("3f2a91c0")?.data == image)
        #expect(fake.asked.count == before, "kept: asked once")
    }

    @Test func bytesThatDontHashToTheirNameAreNotKept() {
        let cache = RemoteDesignCache()
        let key = RemoteDesignCache.Key(host: Self.host, design: DesignID(rawValue: "d"))
        #expect(!cache.store(Data("evil".utf8), sha256: RemoteDesignCache.sha256(Data("good".utf8)), in: key))
        #expect(cache.object(key, sha256: RemoteDesignCache.sha256(Data("good".utf8))) == nil)
        #expect(cache.store(Data("good".utf8), sha256: RemoteDesignCache.sha256(Data("good".utf8)), in: key))
    }

    @Test func memoryGivesUpTheDesignsUsedLeastRecentlyButKeepsWhatPathsName() {
        let cache = RemoteDesignCache(memoryBudget: 2_500)
        let keys = ["a", "b", "c"].map { RemoteDesignCache.Key(host: Self.host, design: DesignID(rawValue: $0)) }
        for key in keys {
            let data = Self.bytes(1_000, seed: UInt8(key.design.rawValue.utf8.first!))
            let sha = RemoteDesignCache.sha256(data)
            cache.store(data, sha256: sha, in: key)
            cache.setPaths(["A.dc.html": sha], for: key)
        }
        #expect(cache.memoryBytes <= 2_500)
        #expect(cache.file(keys[0], path: "A.dc.html") == nil, "the oldest design's bytes left memory")
        #expect(cache.paths(keys[0]).count == 1, "its path map stays, so a sync fetches it again")
        #expect(cache.file(keys[2], path: "A.dc.html") != nil)
    }

    @Test func aCacheOnDiskReadsBackWhatMemoryGaveUp() throws {
        let directory = try makeScratchDirectory("dcache")
        let cache = RemoteDesignCache(directory: directory, memoryBudget: 1_500)
        let first = RemoteDesignCache.Key(host: Self.host, design: DesignID(rawValue: "a"))
        let second = RemoteDesignCache.Key(host: Self.host, design: DesignID(rawValue: "b"))
        let data = Self.bytes(1_000)
        let sha = RemoteDesignCache.sha256(data)
        cache.store(data, sha256: sha, in: first)
        cache.setPaths(["A.dc.html": sha], for: first)
        cache.store(Self.bytes(1_000, seed: 9), sha256: RemoteDesignCache.sha256(Self.bytes(1_000, seed: 9)), in: second)
        #expect(cache.file(first, path: "A.dc.html") == data)

        cache.remove(first)
        #expect(cache.file(first, path: "A.dc.html") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.host.uuidString).appendingPathComponent("a").path))
    }

    /// A file asked for before any sync (a board's stylesheet on first draw) is fetched then.
    @Test func aFileNotYetSyncedIsFetchedOnDemand() async throws {
        let fake = FakeDesignHost(files: ["A.dc.html": Data("<x-dc/>".utf8)])
        let files = source(fake)
        #expect(await files.projectFile("A.dc.html") == Data("<x-dc/>".utf8))
        #expect(await files.projectFile("nothing.css") == nil)
        #expect(files.cache.paths(files.key) == ["A.dc.html": RemoteDesignCache.sha256(Data("<x-dc/>".utf8))])
    }
}

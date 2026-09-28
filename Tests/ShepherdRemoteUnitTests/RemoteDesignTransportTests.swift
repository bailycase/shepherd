import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Fixed SHA-256 vectors, independent of the cache's hashing implementation.
private let abcSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

private actor ScriptedDesignTransport: RemoteDesignTransport {
    var replies: [Result<RemoteDesignResult, RemoteHostClientError>]
    var requests: [RemoteDesignRequest] = []
    init(_ replies: [Result<RemoteDesignResult, RemoteHostClientError>]) { self.replies = replies }
    func design(_ request: RemoteDesignRequest) async throws -> RemoteDesignResult {
        requests.append(request)
        guard !replies.isEmpty else {
            Issue.record("unexpected request: \(request)")
            throw RemoteHostClientError.disconnected
        }
        return try replies.removeFirst().get()
    }
}

@Suite struct RemoteDesignTransportTests {
    let key = RemoteDesignCache.Key(host: UUID(), design: DesignID(rawValue: "wire"))

    func index(_ hash: String, revision: UInt64 = 1) -> RemoteDesignResult {
        .index(RemoteDesignIndex(snapshot: DesignSnapshot(designID: key.design, revision: revision,
            index: DesignIndex(title: "wire"), boards: [:]),
            files: [.init(path: "A.dc.html", sha256: hash, size: 3)]))
    }

    func files(_ data: Data?, hash: String = abcSHA) -> RemoteDesignResult {
        .files(.init(designID: key.design, revision: 1,
            changed: [.init(path: "A.dc.html", sha256: hash, size: 3, data: data)], unchanged: [], missing: []))
    }

    @Test func inlineBytesUseAnIndependentlyKnownDigest() async throws {
        let transport = ScriptedDesignTransport([.success(index(abcSHA)), .success(files(Data("abc".utf8)))])
        let cache = RemoteDesignCache()
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        try await source.sync()
        #expect(cache.file(key, path: "A.dc.html") == Data("abc".utf8))
        #expect(cache.paths(key) == ["A.dc.html": abcSHA])
    }

    @Test func corruptInlineBytesDoNotPublishAnIndexOrDiscardTheLastGoodFile() async throws {
        let transport = ScriptedDesignTransport([.success(index(emptySHA)), .success(files(Data(), hash: emptySHA)),
                                                .success(index(abcSHA, revision: 2)), .success(files(Data("bad".utf8)))])
        let cache = RemoteDesignCache()
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        try await source.sync()
        do {
            try await source.sync()
            Issue.record("corrupt inline sync succeeded")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "corrupt")
        }
        #expect(source.index?.snapshot.revision == 1)
        #expect(cache.paths(key) == ["A.dc.html": emptySHA])
        #expect(cache.file(key, path: "A.dc.html") == Data())
        #expect(cache.object(key, sha256: abcSHA) == nil)
    }

    @Test(arguments: ["offset", "corrupt", "truncated"])
    func invalidUploadsNeverBecomeCachedAssets(fault: String) async throws {
        let chunk = RemoteDesignChunk(name: "image.png", sha256: abcSHA,
            offset: fault == "offset" ? 1 : 0, total: 3,
            data: Data((fault == "corrupt" ? "bad" : fault == "truncated" ? "" : "abc").utf8))
        let transport = ScriptedDesignTransport([.success(.chunk(chunk))])
        let cache = RemoteDesignCache()
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        do {
            _ = try await source.downloadAsset("image", transport: transport)
            Issue.record("invalid upload succeeded")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == (fault == "offset" ? "protocol" : "corrupt"))
        }
        #expect(cache.asset(key, id: "image") == nil)
        #expect(cache.partial(key, "asset:image") == nil)
    }

    @Test(arguments: [false, true])
    func aChangedUploadRestartsInsteadOfAppendingToAnOldPrefix(changedTotal: Bool) async throws {
        let cache = RemoteDesignCache()
        cache.setPartial(.init(sha256: changedTotal ? abcSHA : emptySHA, total: changedTotal ? 4 : 3,
                               data: Data("x".utf8)), "asset:image", in: key)
        let transport = ScriptedDesignTransport([
            .success(.chunk(.init(name: "image.png", sha256: abcSHA, offset: 1, total: 3, data: Data("bc".utf8)))),
            .success(.chunk(.init(name: "image.png", sha256: abcSHA, offset: 0, total: 3, data: Data("abc".utf8)))),
        ])
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        let asset = try await source.downloadAsset("image", transport: transport)
        #expect(asset.data == Data("abc".utf8))
        let requests = await transport.requests
        #expect(requests.compactMap { if case .asset(_, _, let offset) = $0 { offset } else { nil } } == [1, 0])
        #expect(cache.partial(key, "asset:image") == nil)
        #expect(cache.asset(key, id: "image")?.data == Data("abc".utf8))
    }

    @Test(arguments: ["offset", "total", "corrupt", "truncated"])
    func invalidFileChunksLeaveThePublishedCacheUntouched(fault: String) async throws {
        let first = RemoteDesignChunk(sha256: abcSHA, offset: fault == "offset" ? 1 : 0,
                                     total: 3, data: Data("a".utf8))
        let second = RemoteDesignChunk(sha256: abcSHA, offset: 1, total: fault == "total" ? 4 : 3,
                                      data: Data((fault == "corrupt" ? "XX" : "").utf8))
        let transport = ScriptedDesignTransport([
            .success(index(abcSHA)), .success(files(nil)), .success(.chunk(first)), .success(.chunk(second)),
        ])
        let cache = RemoteDesignCache()
        #expect(cache.store(Data(), sha256: emptySHA, in: key))
        cache.setPaths(["A.dc.html": emptySHA], for: key)
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        do {
            try await source.sync()
            Issue.record("invalid file download succeeded")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == (["offset", "total"].contains(fault) ? "protocol" : "corrupt"))
        }
        #expect(source.index == nil)
        #expect(cache.file(key, path: "A.dc.html") == Data())
        #expect(cache.object(key, sha256: abcSHA) == nil)
        #expect(cache.partial(key, "file:A.dc.html") == nil)
    }

    @Test(arguments: [false, true])
    func fileChunksMustMatchTheirDeclaredHashAndLength(wrongHash: Bool) async throws {
        let transport = ScriptedDesignTransport([
            .success(index(abcSHA)), .success(files(nil)),
            .success(.chunk(.init(sha256: wrongHash ? emptySHA : abcSHA, offset: 0,
                                  total: wrongHash ? 3 : 4, data: Data("abc".utf8)))),
            .success(.chunk(.init(sha256: abcSHA, offset: 3, total: 4, data: Data()))),
        ])
        let cache = RemoteDesignCache()
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        do {
            try await source.sync()
            Issue.record("inconsistent chunk metadata accepted")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == (wrongHash ? "protocol" : "corrupt"))
        }
        #expect(source.index == nil)
        #expect(cache.paths(key).isEmpty)
        #expect(cache.object(key, sha256: abcSHA) == nil)
        #expect(cache.partial(key, "file:A.dc.html") == nil)
    }

    @Test func aSecondStaleReplyStopsWithoutPublishingAnIndex() async throws {
        let stale = RemoteHostClientError.rejected(code: RemoteDesignCode.staleFile, message: "changed")
        let transport = ScriptedDesignTransport([.success(index(abcSHA)), .failure(stale),
                                                .success(index(abcSHA)), .failure(stale)])
        let cache = RemoteDesignCache()
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        do {
            try await source.sync()
            Issue.record("repeated stale file succeeded")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == RemoteDesignCode.staleFile)
        }
        #expect(source.index == nil && cache.paths(key).isEmpty)
        #expect(await transport.requests.count == 4)
    }

    @Test func aStaleFileRetriesWithTheNewIndex() async throws {
        let transport = ScriptedDesignTransport([
            .success(index(emptySHA)), .failure(.rejected(code: RemoteDesignCode.staleFile, message: "changed")),
            .success(index(abcSHA, revision: 2)), .success(files(Data("abc".utf8))),
        ])
        let cache = RemoteDesignCache()
        let source = RemoteDesignSource(key: key, cache: cache) { transport }
        try await source.sync()
        #expect(source.index?.snapshot.revision == 2)
        #expect(cache.file(key, path: "A.dc.html") == Data("abc".utf8))
        let requests = await transport.requests
        #expect(requests.filter { if case .index = $0 { true } else { false } }.count == 2)
    }
}

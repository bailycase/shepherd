import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdApp

@MainActor
struct DesignImageCacheTests {
    @Test func designsShareOneBudgetAndVisibleBoardsSurviveEviction() throws {
        let image = DesignRenderImageTests.image(16, 16, noisy: false)
        let cost = DesignImageCache.cost(image)
        let cache = DesignImageCache(limit: cost * 2)
        let first = UUID(), second = UUID(), third = UUID()
        let path = try #require(DesignPath("Main.dc.html"))
        var evicted = false
        cache.onEvict[second] = { _ in evicted = true }
        cache.protect([path], in: first)
        cache.store(image, sha: "first", for: path, in: first)
        cache.store(image, sha: "second", for: path, in: second)
        cache.store(image, sha: "third", for: path, in: third)
        #expect(cache.bytes == cost * 2)
        #expect(cache.sha(path, in: first) == "first")
        #expect(cache.image(path, in: second) == nil && evicted)
        #expect(cache.sha(path, in: third) == "third", "Identical board names never alias across designs or hosts")
        cache.removeAll(in: first)
        #expect(cache.bytes == cost)
        #expect(cache.sha(path, in: third) == "third")
    }

    @Test(arguments: [false, true])
    func anEmptyLatestSnapshotKeepsItsRevisionFenceUntilTheDesignIsPruned(wasNonempty: Bool) throws {
        let id = DesignID(), path = try #require(DesignPath("Main.dc.html"))
        let old = DesignSnapshot(designID: id, revision: 1,
                                 index: DesignIndex(title: "Design", boards: [path: .init(x: 0, y: 0, w: 100, h: 100)], order: [path]),
                                 boards: [path: "old"])
        let empty = DesignSnapshot(designID: id, revision: 2, index: DesignIndex(title: "Design", boards: [:], order: []), boards: [:])
        let rasterizer = DesignRasterizer()
        let thumbnails = DesignThumbnails(rasterizer: rasterizer)
        if wasNonempty { thumbnails.update(id, snapshot: old) }
        thumbnails.update(id, snapshot: empty)
        thumbnails.prune(keeping: [id])
        thumbnails.update(id, snapshot: old)
        #expect(thumbnails.entries[id] == nil && thumbnails.image(id) == nil)
        #expect(rasterizer.pending == 0 && rasterizer.images.bytes == 0)
        thumbnails.prune(keeping: [])
        thumbnails.update(id, snapshot: old)
        #expect(thumbnails.entries[id]?.revision == 1, "Removing the design also removes its watermark")
    }

    @Test func hidingAnOversizedVisibleBoardReleasesItsProtection() throws {
        let image = DesignRenderImageTests.image(16, 16, noisy: false)
        let cache = DesignImageCache(limit: DesignImageCache.cost(image) - 1)
        let owner = UUID(), path = try #require(DesignPath("Main.dc.html"))
        cache.protect([path], in: owner)
        cache.store(image, sha: "drawing", for: path, in: owner)
        #expect(cache.count == 1)
        cache.protect([], in: owner)
        #expect(cache.bytes == 0 && cache.count == 0)
    }
}

import AppKit
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import DesignSurfaceKit
@testable import ShepherdApp

@Suite(.mainActorExclusive)
@MainActor
struct DesignSmallPictureTests {
    @Test func visiblePicturesShareBudgetAndReloadAfterEvictionWithoutCrossingHosts() async throws {
        let id = DesignID(), path = try DesignPath.validate("Main.dc.html")
        let size = CGSize(width: 200, height: 2_000)
        let index = DesignIndex(title: "Test", boards: [path: .init(x: 0, y: 0, w: size.width, h: size.height)], order: [path])
        func snapshot(_ revision: UInt64) -> DesignSnapshot {
            DesignSnapshot(designID: id, revision: revision, index: index, boards: [path: "same-board-sha"])
        }
        func surface(_ color: String) -> DesignSurface {
            DesignSurface(designID: id, files: [path.rawValue: Data("""
                <!doctype html><html><head><script src="./support.js"></script></head>
                <body style="margin:0;background:\(color)"><x-dc><div style="width:200px;height:2000px;background:\(color)"></div></x-dc></body></html>
                """.utf8)], network: .none)
        }
        // A tiny test budget makes every unprotected image evict deterministically.
        let rasterizer = DesignRasterizer(imageLimit: 1)
        let local = DesignThumbnails(rasterizer: rasterizer), remote = DesignThumbnails(rasterizer: rasterizer)
        let boards = DesignBoardPictures(rasterizer: rasterizer)
        var localSurface = surface("#ff0000")
        let remoteSurface = surface("#0000ff")
        local.surface = { _ in localSurface }; remote.surface = { _ in remoteSurface }; boards.surface = { _ in localSurface }
        local.update(id, snapshot: snapshot(1)); remote.update(id, snapshot: snapshot(1)); boards.request(id, snapshot: snapshot(1))
        #expect(rasterizer.pending == 0 && rasterizer.images.bytes == 0, "Metadata does not render a hidden catalog")
        local.demand(id, visible: true); remote.demand(id, visible: true)
        boards.demand(id, path, visible: true, consumer: "picker")
        try await eventuallyOnMain("the three visible pictures") { local.image(id) != nil && remote.image(id) != nil && boards.image(id, path) != nil }
        let first = try #require(local.image(id)), second = try #require(remote.image(id)), board = try #require(boards.image(id, path))
        #expect(max(first.width, first.height) <= Int(AppLayout.designThumbnailPixelWidth))
        #expect(max(board.width, board.height) <= Int(AppLayout.referenceRowPicturePixels))
        #expect(rasterizer.images.bytes == [first, second, board].reduce(0) { $0 + DesignImageCache.cost($1) })
        #expect(DesignElementCropTests.middle(first).0 > 200 && DesignElementCropTests.middle(second).2 > 200)
        local.demand(id, visible: false); remote.demand(id, visible: false)
        boards.demand(id, path, visible: false, consumer: "picker")
        #expect(rasterizer.images.bytes == 0)
        #expect(local.image(id) == nil && boards.image(id, path) == nil)
        local.demand(id, visible: true)
        try await eventuallyOnMain("a visible card to reload after eviction") { local.image(id) != nil }
        localSurface = surface("#00ff00")
        local.update(id, snapshot: snapshot(2))
        #expect(local.image(id) == nil, "A support-only revision invalidates the old board hash")
        try await eventuallyOnMain("the new revision") { local.image(id).map { DesignElementCropTests.middle($0).1 > 200 } ?? false }
        local.update(id, snapshot: snapshot(1))
        #expect(local.entries[id]?.revision == 2, "Late metadata cannot roll back a revision")
        local.prune(keeping: []); remote.prune(keeping: []); boards.prune(keeping: [])
        #expect(rasterizer.images.count == 0 && rasterizer.images.bytes == 0)

        // Removal/recreation while a capture is in flight cannot resurrect an old cache owner.
        localSurface = surface("#ff0000")
        local.update(id, snapshot: snapshot(3)); local.demand(id, visible: true)
        local.prune(keeping: [])
        localSurface = remoteSurface
        local.update(id, snapshot: snapshot(3)); local.demand(id, visible: true)
        try await eventuallyOnMain("only the replacement owner to land") { rasterizer.isIdle && local.image(id) != nil }
        #expect(DesignElementCropTests.middle(try #require(local.image(id))).2 > 200)
        #expect(rasterizer.images.count == 1)
        local.prune(keeping: [])
        #expect(rasterizer.images.bytes == 0)
        #expect(rasterizer.peakWebViews <= 1)
    }
}

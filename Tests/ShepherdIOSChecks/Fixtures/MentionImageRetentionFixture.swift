import Foundation
import UIKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Real MobileDesigns requests, real host libraries and the renderer's real 48-image cache.
/// Only drawing is controlled: no WebKit timing is needed to prove ownership and late fences.
@MainActor enum MentionImageRetentionFixture {
    static let boardCount = DesignRendering.imageBudget + 6
    static func path(_ index: Int) -> DesignPath { DesignPath("Board-\(index).dc.html")! }

    static func hosts() -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        let boards = Dictionary(uniqueKeysWithValues: (0..<boardCount).map {
            (path($0), DesignIndex.Board(x: 0, y: 0, w: 80, h: 60, title: "Board \($0)"))
        })
        let files = Dictionary(uniqueKeysWithValues: (0..<boardCount).map {
            (path($0).rawValue, Data("<html><body>Board \($0)</body></html>".utf8))
        })
        let items = [DesignsFixtures.checkout, DesignsFixtures.events].map { id in
            FixtureDesigns.Item(design: Design(id: id, name: id.rawValue, createdAt: 1, boardCount: boardCount),
                                revision: 3, index: DesignIndex(title: id.rawValue, boards: boards,
                                                               order: (0..<boardCount).map(path)),
                                files: files, comments: DesignComments())
        }
        for index in 0...1 {
            hosts[index].designs = FixtureDesigns(designs: items)
            hosts[index].state.designs = items.map(\.design)
        }
        return hosts
    }

    static func item(_ index: Int, revision: UInt64 = 3, design: DesignID = DesignsFixtures.checkout) -> DesignMentionItem {
        DesignMentionItem(kind: .board, reference: DesignReference(designID: design, board: path(index))!,
                          title: "Board \(index)", breadcrumb: [], revision: revision)
    }

    @MainActor final class Drawing {
        var count = 0
        var holdNext = false
        var failNext = false
        var held: CheckedContinuation<Void, Never>?

        func draw() async -> UIImage? {
            count += 1
            if holdNext {
                holdNext = false
                await withCheckedContinuation { held = $0 }
            }
            if failNext { failNext = false; return nil }
            // Distinct, known-size CGImages make retention assertions independent of PNG size.
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return UIImage(cgImage: context.makeImage()!)
        }

        func release() {
            let continuation = held
            held = nil
            continuation?.resume()
        }
    }

    static func run(_ app: MobileApp) async {
        let store = MobileDesigns.of(app.hosts)
        let rendering = DesignRendering()
        let drawing = Drawing()
        rendering.drawForTesting = { _, _, _ in await drawing.draw() }
        store.mentionRenderingForTesting = rendering
        defer { drawing.release(); store.mentionRenderingForTesting = nil }
        await store.refresh()
        await FixtureCheck.wait("mention libraries", seconds: 5) {
            store.library(FixtureData.studio)?.listing != nil && store.library(FixtureData.buildBox)?.listing != nil
        }
        func check(_ ok: Bool, _ message: String) { FreshnessFixtures.check(ok, message) }
        func load(_ item: DesignMentionItem, host: UUID = FixtureData.studio) async {
            store.wantMentionPicture(item, host: host)
            await FixtureCheck.wait("mention picture \(item.title)", seconds: 5) { store.mentionPicture(item, host: host) != nil }
        }

        await load(item(0))
        // Hold the actual picker value in two consumers, not a separate strong UIImage cache.
        func pickerValue() -> SHReferenceImage? {
            store.mentionPicture(item(0), host: FixtureData.studio).map {
                SHReferenceImage(id: "visible", image: Image(uiImage: $0))
            }
        }
        weak var first = store.mentionPicture(item(0), host: FixtureData.studio)
        var firstWindow = pickerValue()
        var secondWindow = pickerValue()
        await load(item(1))
        weak var evicted = store.mentionPicture(item(1), host: FixtureData.studio)
        for index in 2..<(DesignRendering.imageBudget + 2) { await load(item(index)) }
        check(rendering.renderedImages == DesignRendering.imageBudget, "renderer reaches, never exceeds, its existing image bound")
        check(rendering.imageBytesForTesting == DesignRendering.imageBudget * 256, "renderer backing bytes plateau at 48 small images")
        await FixtureCheck.wait("unowned evicted image released", seconds: 5) { evicted == nil }
        check(store.mentionPicture(item(0), host: FixtureData.studio) === first && first != nil
              && firstWindow != nil && secondWindow != nil,
              "picker-owned images stay available after renderer eviction")
        firstWindow = nil
        check(first != nil && secondWindow != nil, "closing one picker preserves the other consumer's image")
        secondWindow = nil
        await FixtureCheck.wait("last picker owner released", seconds: 5) { first == nil }
        check(store.mentionImageCountForTesting == DesignRendering.imageBudget
              && store.mentionImageBytesForTesting == rendering.imageBytesForTesting,
              "mention lookup adds no hidden strong-image retention")
        await load(item(0))
        check(store.mentionPicture(item(0), host: FixtureData.studio) != nil, "an evicted image can render again on reentry")

        // Revision-only changes may keep the same source hash. They must not accumulate lookups.
        for revision in UInt64(4)...UInt64(60) { await load(item(0, revision: revision)) }
        check(store.mentionImageCountForTesting == 1 && store.mentionPicture(item(0), host: FixtureData.studio) == nil,
              "superseded revisions are pruned across the design")
        let count = drawing.count
        store.wantMentionPicture(item(0, revision: 60), host: FixtureData.studio)
        store.wantMentionPicture(item(0, revision: 59), host: FixtureData.studio)
        check(drawing.count == count && store.mentionRequestsForTesting == 0,
              "two consumers share the image and an older catalog cannot replace it")

        drawing.holdNext = true
        let superseding = store.mentionCompletionsForTesting
        let old = item(boardCount - 4, revision: 61)
        store.wantMentionPicture(old, host: FixtureData.studio)
        await FixtureCheck.wait("old revision drawing held", seconds: 5) { drawing.held != nil }
        let before = store.mentionPicturesVersion
        let newer = item(boardCount - 4, revision: 62)
        store.wantMentionPicture(newer, host: FixtureData.studio)
        store.wantMentionPicture(newer, host: FixtureData.studio)
        drawing.release()
        await FixtureCheck.wait("replacement revision landed", seconds: 5) {
            store.mentionPicture(newer, host: FixtureData.studio) != nil && store.mentionRequestsForTesting == 0
                && store.mentionCompletionsForTesting >= superseding + 2
        }
        check(store.mentionCompletionsForTesting == superseding + 2, "two pending consumers share one replacement job")
        check(store.mentionPicturesVersion == before + 1 && store.mentionPicture(old, host: FixtureData.studio) == nil,
              "superseded completion cannot publish or clear its replacement's pending reservation")

        let retry = item(boardCount - 3, revision: 62)
        drawing.failNext = true
        let completed = store.mentionCompletionsForTesting
        store.wantMentionPicture(retry, host: FixtureData.studio)
        await FixtureCheck.wait("failed drawing released", seconds: 5) { store.mentionCompletionsForTesting > completed }
        check(store.mentionRequestsForTesting == 0 && store.mentionPicture(retry, host: FixtureData.studio) == nil,
              "failed drawing leaves no stuck wanted entry")
        await load(retry)
        await load(item(0, revision: 62))
        await load(item(0, revision: 62, design: DesignsFixtures.events))
        let checkout = store.mentionPicture(retry, host: FixtureData.studio)
        let sameBoard = store.mentionPicture(item(0, revision: 62), host: FixtureData.studio)
        check(checkout != nil && sameBoard != nil && checkout !== sameBoard, "different boards keep separate pictures")
        check(store.mentionPicture(item(0, revision: 62, design: DesignsFixtures.events), host: FixtureData.studio) !== sameBoard,
              "the same board path in different designs keeps separate pictures")

        app.hosts.disconnect(FixtureData.buildBox)
        await FixtureCheck.wait("mention host unavailable", seconds: 5) { store.library(FixtureData.buildBox) == nil }
        let other = item(0, revision: 62)
        store.wantMentionPicture(other, host: FixtureData.buildBox)
        check(store.mentionRequestsForTesting == 0, "missing library reserves no wanted entry")
        app.hosts.retry(FixtureData.buildBox)
        await FixtureCheck.wait("mention host reconnected", seconds: 5) { store.library(FixtureData.buildBox) != nil }
        await load(other, host: FixtureData.buildBox)
        weak var forgotten = store.mentionPicture(other, host: FixtureData.buildBox)
        check(forgotten != nil && forgotten !== sameBoard && store.mentionPicture(other, host: FixtureData.studio) === sameBoard,
              "host keys are isolated and reconnect can retry an unavailable request")

        drawing.holdNext = true
        let pending = item(boardCount - 2, revision: 62)
        store.wantMentionPicture(pending, host: FixtureData.buildBox)
        await FixtureCheck.wait("forgotten host drawing held", seconds: 5) { drawing.held != nil }
        let finishing = store.mentionCompletionsForTesting
        do { try app.hosts.forget(FixtureData.buildBox) }
        catch { FixtureCheck.fail("forget mention host: \(error)") }
        await FixtureCheck.wait("mention host forgotten", seconds: 5) {
            store.library(FixtureData.buildBox) == nil && store.mentionPicture(other, host: FixtureData.buildBox) == nil
        }
        let forgottenVersion = store.mentionPicturesVersion
        drawing.release()
        await FixtureCheck.wait("forgotten drawing completed", seconds: 5) { store.mentionCompletionsForTesting > finishing }
        await FixtureCheck.wait("forgotten image released", seconds: 5) { forgotten == nil }
        check(store.mentionRequestsForTesting == 0
              && store.mentionPicture(pending, host: FixtureData.buildBox) == nil
              && store.mentionPicturesVersion == forgottenVersion,
              "forget releases cached images and late rendering cannot reinsert or notify")
        check(store.mentionPicture(retry, host: FixtureData.studio) === checkout, "forget preserves another host's visible image")
        print("FIXTURE MENTION RETENTION budget=\(DesignRendering.imageBudget) rendererImages=\(rendering.renderedImages) backingBytes=\(rendering.imageBytesForTesting)")
    }
}

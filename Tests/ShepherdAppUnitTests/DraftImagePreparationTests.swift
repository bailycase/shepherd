import AppKit
import Foundation
import Testing
@testable import ShepherdApp

/// New thread and New design drafts: Send waits while dropped images are still being read, and a
/// read lands in the draft it was dropped into.
@Suite("Draft image preparation", .timeLimit(.minutes(1)))
@MainActor
struct DraftImagePreparationTests {
    /// A held read: the test decides when it returns, and with what.
    @MainActor final class HeldRead {
        var held: CheckedContinuation<[(URL, ImageFile?)], Never>?
        var started: CheckedContinuation<Void, Never>?
        func read(_ providers: [NSItemProvider]) async -> [(URL, ImageFile?)] {
            await withCheckedContinuation { continuation in
                held = continuation
                started?.resume()
                started = nil
            }
        }
    }

    private func png() throws -> (URL, ImageFile) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("draft-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("shot.png")
        try ImageViewerStateTests.flat(64).write(to: url)
        return (url, try #require(ImageFile(url: url)))
    }

    @Test func newThreadSendWaitsForImagesBeingRead() async throws {
        let (url, file) = try png()
        let draft = NewThreadState()
        let read = HeldRead()
        draft.prepareImages = read.read
        await withCheckedContinuation { started in
            read.started = started
            draft.attach([NSItemProvider()])
        }
        #expect(draft.imagesPending != nil, "Send is held while the image is read")
        #expect(draft.attachments.isEmpty)
        read.held?.resume(returning: [(url, file)])
        await withCheckedContinuation { landed in
            withObservationTracking { _ = draft.attachments } onChange: { landed.resume() }
        }
        #expect(draft.imagesPending == nil)
        #expect(draft.attachments.items.map(\.name) == ["shot.png"])
    }

    @Test func newDesignSendWaitsForImagesBeingRead() async throws {
        let (url, file) = try png()
        let draft = NewDesignState()
        let read = HeldRead()
        draft.prepareImages = read.read
        await withCheckedContinuation { started in
            read.started = started
            draft.attach([NSItemProvider()])
        }
        #expect(draft.imagesPending != nil)
        read.held?.resume(returning: [(url, file)])
        await withCheckedContinuation { landed in
            withObservationTracking { _ = draft.attachments } onChange: { landed.resume() }
        }
        #expect(draft.imagesPending == nil)
        #expect(draft.attachments.items.count == 1)
    }
}

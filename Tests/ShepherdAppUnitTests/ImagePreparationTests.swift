import AppKit
import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// Image preparation for every entry point runs off the main actor and lands in order, within the limits.
@Suite("Image preparation")
@MainActor
struct ImagePreparationTests {
    @Test func dropsAreReadOffMainInOrderWithinTheLimits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("image-prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try (0..<(NativeImage.maxPerSend + 1)).map { index in
            let url = folder.appendingPathComponent("shot-\(index).png")
            try ImageViewerStateTests.flat(1800).write(to: url)
            return url
        }
        let note = folder.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: note)
        let files = await ImageFile.read([note] + urls)
        #expect(files.map(\.0) == [note] + urls, "results keep the drop's order")
        var attachments = ComposerAttachments()
        attachments.add(files: files)
        #expect(attachments.items.map(\.name) == urls.prefix(NativeImage.maxPerSend).map(\.lastPathComponent))
        #expect(attachments.error == "At most \(NativeImage.maxPerSend) images per message.")
        #expect(attachments.items.allSatisfy { $0.thumbnail != nil && $0.pixels == CGSize(width: 1800, height: 1800) })
    }

    @Test func aTranscriptThumbnailIsDecodedOffMainAtTheThumbnailSize() async throws {
        let data = try ImageViewerStateTests.flat(3000)
        let images = NativeThreadImages()
        images.configure(sessionID: "s", fetch: { request in
            guard case .image(_, let id, let offset) = request else { return .failure(code: "invalid", message: "") }
            let end = min(data.count, offset + NativeImage.chunkBytes)
            return .imageChunk(value: NativeImageChunk(imageID: id, mimeType: "image/png", totalBytes: data.count, offset: offset,
                                                       data: data[offset..<end]))
        })
        let load = ThreadImageLoad(NativeImageRef(id: "a", mimeType: "image/png", width: 3000, height: 3000, byteCount: data.count))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            withObservationTracking { _ = load.state } onChange: { done.resume() }
            load.load(from: images)
        }
        guard case .picture(let bytes, let picture) = load.state else { Issue.record("not a picture: \(load.state)"); return }
        #expect(bytes == data)
        #expect(max(picture.size.width, picture.size.height) <= ThreadImageLoad.thumbnailPixels)

        // A row that goes away before its image lands (a lazy remount) never receives it.
        let gone = ThreadImageLoad(NativeImageRef(id: "a", mimeType: "image/png", width: 3000, height: 3000, byteCount: data.count))
        gone.load(from: images)
        gone.cancel()
        await Task.yield()
        #expect(gone.state == .loading)
    }
}

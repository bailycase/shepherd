import AppKit
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// A user message that carried pictures keeps them in pi's session; the thread's blocks never do. A client that did not send them
/// (another client, or the same one after a restart) asks the host for previews, which stay under one 1 MiB frame.
@Suite("Saved images in a thread", .integrationTimeLimit)
struct SavedImagesTests {
    /// A PNG of random pixels, so it is large and does not shrink: `side`² × 4 bytes or so.
    static func noisyPNG(side: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var generator = SystemRandomNumberGenerator()
        for row in 0..<rep.pixelsHigh {
            let bytes = rep.bitmapData! + row * rep.bytesPerRow
            for i in 0..<(side * 4) { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        }
        return rep.representation(using: .png, properties: [:])!
    }

    static let base = 1_733_000_000_000.0

    /// pi's saved list: a user message with the given images (and words), then a reply.
    static func history(images: [Data]) throws -> Data {
        let user: [String: Any] = ["role": "user", "timestamp": base, "content":
            [["type": "text", "text": "look at these"]] + images.map { ["type": "image", "mimeType": "image/png", "data": $0.base64EncodedString()] }]
        let reply: [String: Any] = ["role": "assistant", "stopReason": "stop", "timestamp": base + 1000,
                                    "content": [["type": "text", "text": "Seen."]]]
        return try JSONSerialization.data(withJSONObject: [user, reply])
    }

    @Test func aReloadedThreadServesPreviewsOfItsSavedImagesWithinOneFrame() async throws {
        let scratch = try makeScratchDirectory("saved-images")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let small = Self.noisyPNG(side: 24)
        let big = Self.noisyPNG(side: 700)
        #expect(big.count > NativeImage.maxBytes / 2, "a real multi-hundred-KiB picture")
        let file = scratch.appendingPathComponent("history.json")
        try Self.history(images: [small, big, big, big]).write(to: file)

        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": file.path])
        let snapshot = try await pi.ready()
        #expect(snapshot.supportedActions.contains("savedImages"))
        let user = try #require(snapshot.messages.first { $0.role == "user" })
        #expect(user.blocks.filter { $0.kind == .unsupportedImage }.count == 4, "the thread says how many")
        #expect(RPCThreadState.bytes(snapshot) < big.count, "no snapshot carries the pictures")

        guard case .images(let previews) = try await pi.request(.images(expectedSessionID: snapshot.piSessionID, entryID: user.entryID)) else {
            Issue.record("expected previews")
            return
        }
        #expect(previews.count == 4)
        #expect(previews[0].data == small, "a small one is served as it is")
        #expect(previews.allSatisfy { $0.data.count <= NativeImage.previewBytes && $0.mimeType.hasPrefix("image/") && NSImage(data: $0.data) != nil })
        let frame = try NDJSON.encode(RemoteReply.nativeThread(id: 1, result: .images(value: previews)))
        #expect(frame.count - 1 <= NDJSON.maxPayloadBytes, "four previews fit one frame")

        #expect(try await pi.request(.images(expectedSessionID: snapshot.piSessionID, entryID: "user:1")).failureCode == "unknown_entry")
        #expect(try await pi.request(.images(expectedSessionID: "stale", entryID: user.entryID)).failureCode == "stale_session")
    }

    /// The original comes back whole through 256 KiB slices, byte for byte, each reply inside one frame; a picture over the send
    /// limit is refused and a bad offset or a stale session fails. The previews are never what the slices carry.
    @Test func theOriginalReadsBackByteIdenticalInBoundedChunks() async throws {
        let scratch = try makeScratchDirectory("saved-chunks")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = Self.noisyPNG(side: 700)
        #expect(original.count > 2 * NativeImage.chunkBytes && original.count <= NativeImage.maxBytes, "needs several chunks, still sendable")
        let odd = Data((0..<(NativeImage.chunkBytes + 7)).map { UInt8($0 % 251) }) // not a multiple of 3: padded base64
        let huge = Data(count: NativeImage.maxBytes + 1)
        let file = scratch.appendingPathComponent("history.json")
        try Self.history(images: [Self.noisyPNG(side: 24), original, odd, huge]).write(to: file)
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": file.path])
        let s = try await pi.ready()
        let user = try #require(s.messages.first { $0.role == "user" })

        func read(_ index: Int) async throws -> Data? {
            var data = Data()
            while true {
                let result = try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: index, offset: data.count))
                guard case .imageChunk(let chunk) = result else { return nil }
                #expect(chunk.offset == data.count && chunk.data.count <= NativeImage.chunkBytes)
                let frame = try NDJSON.encode(RemoteReply.nativeThread(id: 1, result: result))
                #expect(frame.count - 1 <= NDJSON.maxPayloadBytes, "a slice fits one frame")
                data.append(chunk.data)
                if data.count == chunk.total { return data }
            }
        }
        #expect(try await read(1) == original, "byte identical, not the preview")
        #expect(try await read(2) == odd, "a length that is not a multiple of 3")
        #expect(try await read(3) == nil, "over the send limit is refused")
        #expect(try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: 3, offset: 0)).failureCode == "too_large")
        #expect(try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: 1, offset: 4)).failureCode == "invalid")
        #expect(try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: 1, offset: original.count)).failureCode == "invalid")
        #expect(try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: 9, offset: 0)).failureCode == "unknown_image")
        #expect(try await pi.request(.imageChunk(expectedSessionID: "stale", entryID: user.entryID, index: 1, offset: 0)).failureCode == "stale_session")
    }

    /// Only the first `maxPerSend` pictures are ever decoded: a message with more answers no more than four previews.
    @Test func onlyTheFirstFourPicturesOfAMessageArePreviewed() async throws {
        let scratch = try makeScratchDirectory("saved-cap")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("history.json")
        try Self.history(images: (0..<7).map { _ in Self.noisyPNG(side: 16) }).write(to: file)
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": file.path])
        let s = try await pi.ready()
        let user = try #require(s.messages.first { $0.role == "user" })
        guard case .images(let previews) = try await pi.request(.images(expectedSessionID: s.piSessionID, entryID: user.entryID)) else {
            Issue.record("expected previews"); return
        }
        #expect(previews.count == NativeImage.maxPerSend)
        #expect(try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: 4, offset: 0)).failureCode == "unknown_image")
    }

    /// Under 100 KB can hold 81 megapixels: the host serves no preview (an empty entry) and no original of it, and a
    /// reasonable panorama still previews and reads back.
    @Test func aPictureThatPromisesHugePixelsIsNeverDecodedOrServed() async throws {
        let scratch = try makeScratchDirectory("saved-bomb")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bomb = TestPNG.zeros(width: 9_000, height: 9_000)
        let panorama = TestPNG.zeros(width: 12_000, height: 3_000)
        let file = scratch.appendingPathComponent("history.json")
        try Self.history(images: [bomb, panorama]).write(to: file)
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": file.path])
        let s = try await pi.ready()
        let user = try #require(s.messages.first { $0.role == "user" })
        guard case .images(let previews) = try await pi.request(.images(expectedSessionID: s.piSessionID, entryID: user.entryID)) else {
            Issue.record("expected previews"); return
        }
        #expect(previews.count == 2 && previews[0].data.isEmpty, "the bomb has no preview")
        #expect(previews[1].data == panorama, "a panorama, small in bytes, passes as it is")
        #expect(try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: 0, offset: 0)).failureCode == "too_many_pixels")
        guard case .imageChunk(let chunk) = try await pi.request(.imageChunk(expectedSessionID: s.piSessionID, entryID: user.entryID, index: 1, offset: 0)) else {
            Issue.record("expected the panorama"); return
        }
        #expect(chunk.data == panorama)
    }
}

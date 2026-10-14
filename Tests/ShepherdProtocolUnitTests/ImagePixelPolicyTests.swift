import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestKit

@Suite("Image pixel policy and frame bounds")
struct ImagePixelPolicyTests {
    /// Under 100 KB can hold 81 megapixels: the header, not the byte count, decides. A reasonable panorama and an ordinary
    /// screenshot pass, and 64 MP exactly passes.
    @Test func theHeaderDecidesNotTheByteCount() {
        let bomb = TestPNG.zeros(width: 9_000, height: 9_000)
        #expect(bomb.count < NativeImage.previewBytes, "small in bytes")
        #expect(NativeImage.pixelSize(of: bomb)?.width == 9_000)
        #expect(!NativeImage.withinPixelPolicy(bomb), "81 MP is over 64 MP")
        #expect(!NativeImage.withinPixelPolicy(Data([1, 2, 3])), "no header, no pass")
        #expect(NativeImage.withinPixelPolicy(TestPNG.zeros(width: 12_000, height: 3_000)), "a panorama is fine")
        #expect(NativeImage.withinPixelPolicy(TestPNG.zeros(width: 1170, height: 2532)))
        #expect(NativeImage.withinPixelPolicy(TestPNG.zeros(width: 8_000, height: 8_000)), "exactly 64 MP passes")
    }

    @Test func anOriginalReadsAtMostNineSlices() {
        #expect(NativeImage.maxChunks == 9 && NativeImage.chunkBytes % 3 == 0)
    }

    /// The worst bytes for JSON and base64 (every byte 0xFF) at the largest a slice or four previews can be, framed as the host
    /// frames them, stay under one 1 MiB frame; `.withoutEscapingSlashes` changes nothing about base64, which has `/` only
    /// unescaped, so the frame is the exact length.
    @Test func theWorstCaseBytesFrameUnderOneMiB() throws {
        let slice = NativeImageChunk(mimeType: "image/png", total: NativeImage.maxBytes, offset: 0,
                                     data: Data(repeating: 0xFF, count: NativeImage.chunkBytes))
        let chunk = try NDJSON.encode(RemoteReply.nativeThread(id: Int.max, result: .imageChunk(value: slice)))
        #expect(chunk.count - 1 <= NDJSON.maxPayloadBytes)
        let previews = (0..<NativeImage.maxPerSend).map { _ in NativeImage(mimeType: "image/jpeg", data: Data(repeating: 0xFF, count: NativeImage.previewBytes), name: String(repeating: "/", count: 200)) }
        let frame = try NDJSON.encode(RemoteReply.nativeThread(id: Int.max, result: .images(value: previews)))
        #expect(frame.count - 1 <= NDJSON.maxPayloadBytes)
        #expect(chunk.count < 400_000 && frame.count < 900_000, "with room to spare, not by a hair")
    }
}

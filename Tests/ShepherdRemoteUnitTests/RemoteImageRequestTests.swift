import CoreGraphics
import Foundation
import ImageIO
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Remote image requests")
struct RemoteImageRequestTests {
    @Test(arguments: ["create", "thread", "message", "conversation", "worker", "answer"], [1, 4])
    func screenshotsFitTheCompleteRemoteFrame(route: String, count: Int) async throws {
        let screenshot = try Self.screenshot()
        let images = Array(repeating: NativeImage(mimeType: "image/png", data: screenshot, name: "Screenshot.png"), count: count)
        let operation = UUID()
        let text = String(repeating: "Look at this screenshot: \"details\"\n", count: 1500)
        let native: @Sendable ([NativeImage]) -> NativeThreadRequest = {
            .send(expectedSessionID: "session", generation: "generation", operationID: operation, text: text, delivery: .followUp, images: $0)
        }
        let project = ProjectID(), task = ProjectTaskID(), agent = AgentID(), space = SpaceID()
        let transport: @Sendable ([NativeImage]) -> ProjectRuntimeTransport = { images in
            switch route {
            case "message": .action(projectID: project, expectedRevision: .max, request: .message(operationID: operation, text: text, images: images))
            case "conversation": .conversation(projectID: project, request: native(images))
            case "worker": .worker(projectID: project, taskID: task, request: native(images))
            default: .answer(projectID: project, expectedRevision: .max, taskID: task, request: native(images))
            }
        }
        let request: @Sendable ([NativeImage]) -> RemoteRequest = { images in
            switch route {
            case "create": .createAgent(id: Int.max, spaceID: space, cwd: nil, model: nil, thinking: nil, initialPrompt: text, initialImages: images)
            case "thread": .nativeThread(id: Int.max, agentID: agent, request: native(images))
            default: .logicalProjectRuntime(id: Int.max, request: transport(images))
            }
        }
        #expect(NativeImage.fitOneSend(images))
        #expect(RemoteHostClient.overFrame(request(images)), "the original screenshots reproduce the remote frame overflow")
        let prepared: [NativeImage]
        switch route {
        case "create": prepared = try await RemoteHostClient.preparingImages(images, request: request)
        case "thread":
            let value = try await RemoteHostClient.preparingImages(native(images)) { .nativeThread(id: Int.max, agentID: agent, request: $0) }
            prepared = value.images
            #expect(value == native(prepared), "session, operation, text and delivery do not change")
        default:
            let value = try await RemoteHostClient.preparingImages(transport(images))
            prepared = value.nativeRequest?.images ?? value.messageImages
            #expect(value == transport(prepared), "Project and operation identities do not change")
        }
        #expect(prepared.count == count)
        #expect(NativeImage.fitOneSend(prepared))
        #expect(!RemoteHostClient.overFrame(request(prepared)))
        var buffer = LineBuffer()
        let lines = try buffer.append(NDJSON.encode(request(prepared)))
        #expect(lines.count == 1)
        #expect(try NDJSON.encode(NDJSON.decode(RemoteRequest.self, from: #require(lines.first))) == NDJSON.encode(request(prepared)))
        #expect(prepared.allSatisfy { CGImageSourceCreateWithData($0.data as CFData, nil) != nil })
        #expect(images.allSatisfy { $0.data == screenshot && $0.mimeType == "image/png" }, "the source attachments stay untouched")
        #expect(try await RemoteHostClient.preparingImages(images, request: request) == prepared, "explicit retries encode the same images")
    }

    @Test func fittingPNGsStayByteForByteUnchanged() async throws {
        let image = try NativeImagePreparation.prepare(Self.screenshot(), name: "Screenshot.png", maxEdge: 100)
        let prepared = try await RemoteHostClient.preparingImages([image]) {
            .nativeThread(id: Int.max, agentID: AgentID(rawValue: "a"), request: .send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "look", delivery: .followUp, images: $0))
        }
        #expect(prepared == [image])
    }

    @Test func aTightBudgetShrinksDimensionsAndAnImpossibleBudgetStops() throws {
        let original = try Self.screenshot()
        let image = try NativeImagePreparation.prepare(original, name: "Screenshot.png", maxBytes: 8000)
        #expect(image.data.count <= 8000)
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 800) < 800)
        #expect(throws: NativeImagePreparation.Failure.tooLarge("Screenshot.png")) {
            try NativeImagePreparation.prepare(original, name: "Screenshot.png", maxBytes: 1)
        }
    }

    @Test(arguments: [false, true])
    func impossibleRequestsAreRefusedBeforeSending(tooMuchText: Bool) async throws {
        let original = [NativeImage(mimeType: "image/png", data: tooMuchText ? try Self.screenshot() : Data(count: 900_000), name: "original.png")]
        do {
            _ = try await RemoteHostClient.preparingImages(original) {
                .nativeThread(id: Int.max, agentID: AgentID(rawValue: "a"), request: .send(expectedSessionID: "s", generation: "g", operationID: UUID(),
                    text: tooMuchText ? String(repeating: "x", count: NDJSON.maxPayloadBytes) : "look", delivery: .followUp, images: $0))
            }
            Issue.record("An oversized or unreadable request must not be sent")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "too_large")
        }
        #expect(original.first?.name == "original.png")
    }

    /// Deterministic high-detail raster: unlike a solid-color image, its PNG exceeds one remote
    /// frame after base64 but remains a valid local attachment. No files or user photos.
    private static func screenshot() throws -> Data {
        let width = 800, height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt32 = 0x12345678
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                random ^= random << 13; random ^= random >> 17; random ^= random << 5
                pixels[index + channel] = UInt8(truncatingIfNeeded: random)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

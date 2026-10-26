import Foundation
import ShepherdCore
import ShepherdProtocol

extension RemoteHostClient {
    /// Fit the complete request, not just each image's RPC limit. JSON carries base64 and the
    /// remote listener's frame is smaller than pi's stdin budget. Work off the caller's actor.
    static func preparingImages(_ images: [NativeImage], request: @escaping @Sendable ([NativeImage]) -> RemoteRequest) async throws -> [NativeImage] {
        guard !images.isEmpty else { return images }
        return try await Task.detached(priority: .userInitiated) {
            guard overFrame(request(images)) else { return images }
            guard NativeImage.fitOneSend(images) else {
                throw RemoteHostClientError.rejected(code: "too_large", message: imagesTooLarge)
            }
            let empty = images.map { NativeImage(mimeType: $0.mimeType, data: Data(), name: $0.name) }
            let overhead = try NDJSON.encode(request(empty)).count - 1
            // Leave room for MIME/name changes and base64 padding. The factory uses Int.max so
            // the eventual request id cannot make a fitting frame overflow.
            let available = NDJSON.maxPayloadBytes - overhead - 1024
            guard available > 0 else {
                throw RemoteHostClientError.rejected(code: "too_large", message: imagesTooLarge)
            }
            let bytesPerImage = (available / 4 * 3) / images.count
            let prepared: [NativeImage]
            do {
                prepared = try images.map { image in
                    guard image.data.count > bytesPerImage else { return image }
                    return try NativeImagePreparation.prepare(image.data, name: image.name ?? "Image", maxBytes: bytesPerImage)
                }
            } catch {
                throw RemoteHostClientError.rejected(code: "too_large", message: imagesTooLarge)
            }
            guard !overFrame(request(prepared)) else {
                throw RemoteHostClientError.rejected(code: "too_large", message: imagesTooLarge)
            }
            return prepared
        }.value
    }

    static func preparingImages(_ native: NativeThreadRequest, request: @escaping @Sendable (NativeThreadRequest) -> RemoteRequest) async throws -> NativeThreadRequest {
        guard case .send(let session, let generation, let operation, let text, let delivery, _, let context, let references, let elements) = native else { return native }
        let make: @Sendable ([NativeImage]) -> NativeThreadRequest = { images in
            .send(expectedSessionID: session, generation: generation, operationID: operation, text: text, delivery: delivery,
                  images: images, designContext: context, designReferences: references, browserElements: elements)
        }
        let images = try await preparingImages(native.images) { request(make($0)) }
        return images == native.images ? native : make(images)
    }

    static func preparingImages(_ transport: ProjectRuntimeTransport) async throws -> ProjectRuntimeTransport {
        switch transport {
        case .action(let project, let revision, .message(let operation, let text, let images)):
            guard let images, !images.isEmpty else { return transport }
            let make: @Sendable ([NativeImage]) -> ProjectRuntimeTransport = {
                .action(projectID: project, expectedRevision: revision, request: .message(operationID: operation, text: text, images: $0))
            }
            return make(try await preparingImages(images) { .logicalProjectRuntime(id: Int.max, request: make($0)) })
        case .conversation(let project, let native):
            let make: @Sendable (NativeThreadRequest) -> ProjectRuntimeTransport = { .conversation(projectID: project, request: $0) }
            return make(try await preparingImages(native) { .logicalProjectRuntime(id: Int.max, request: make($0)) })
        case .worker(let project, let task, let native):
            let make: @Sendable (NativeThreadRequest) -> ProjectRuntimeTransport = { .worker(projectID: project, taskID: task, request: $0) }
            return make(try await preparingImages(native) { .logicalProjectRuntime(id: Int.max, request: make($0)) })
        case .answer(let project, let revision, let task, let native):
            let make: @Sendable (NativeThreadRequest) -> ProjectRuntimeTransport = {
                .answer(projectID: project, expectedRevision: revision, taskID: task, request: $0)
            }
            return make(try await preparingImages(native) { .logicalProjectRuntime(id: Int.max, request: make($0)) })
        default: return transport
        }
    }
}

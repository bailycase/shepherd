import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

extension ThreadPreviewTests {
    @Test(arguments: [false, true])
    func blockedModelKeepsTheDraftAndOffersThePicker(long: Bool) async throws {
        let store = NativeThreadStore()
        defer { store.stop() }
        var snapshot = ActivityThreads.idle
        snapshot.running = false
        snapshot.messages = []
        let model = long ? String(repeating: "long-model-name-", count: 8) : "gpt-6.1-sol"
        let failure = RPCThreadState.modelUnavailableMessage(model)
        let request: NativeThreadStore.Request = { action in
            if case .send = action { return .failure(code: "model_unavailable", message: failure) }
            return .snapshot(value: snapshot)
        }
        let input = ThreadInput()
        let image = ImageAttachment(name: "reference.png", image: NativeImage(mimeType: "image/png", data: Data([1])))
        input.attachments.add([(image.name, image)])
        store.draft = long ? String(repeating: "Please update this design without changing its navigation. ", count: 8) : ""
        let size = CGSize(width: 540, height: 820)
        try await Preview.renderMatrix("composer-blocked-model-\(long ? "long" : "empty")", size: size,
                                       ready: { store.modelUnavailable && !store.busy }) {
            ThreadView(store: store, active: true, isFocused: false, request: request,
                       listModels: { .empty }, retainedInput: input)
                .frame(width: size.width, height: size.height)
                .task {
                    try? await eventuallyOnMain("thread ready") { store.ready }
                    guard !store.modelUnavailable else { return }
                    _ = await store.send(images: [image.image], delivery: .followUp)
                }
        }
        #expect(input.attachments.images == [image.image])
        #expect(store.modelUnavailable)
    }
}

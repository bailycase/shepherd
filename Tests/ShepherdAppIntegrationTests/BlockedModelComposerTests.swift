import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

@Suite("Blocked model composer", .integrationTimeLimit)
struct BlockedModelComposerTests {
    @Test func aRejectedSendKeepsItsDraftAndAttachmentsAndThePickerCanReselectTheSameModel() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.useComposer() }
        }
    }

    @MainActor static func useComposer() async throws {
        AccessibilityNode.enable()
        let store = NativeThreadStore(), input = ThreadInput()
        let snapshot = ComposerThread.snapshot(messages: 0, commands: [])
        let message = RPCThreadState.modelUnavailableMessage("claude-opus-4-5")
        let image = ImageAttachment(name: "design.png", image: NativeImage(mimeType: "image/png", data: Data([1, 2, 3])))
        input.attachments.add([(image.name, image)])
        store.draft = "Please update the design"
        store.attach(files: [NativeAttachedFile(name: "notes.md", path: "/tmp/notes.md")])
        var sends = 0, selections: [String] = []
        let window = OffscreenWindow(size: CGSize(width: 800, height: 700))
        defer { store.stop(); window.close() }
        var value = snapshot
        value.supportedActions.append("sendImages")
        window.show(ThreadView(store: store, active: true, isFocused: false, request: { request in
            switch request {
            case .send(_, _, let id, _, _, let images, _, _, _):
                sends += 1
                #expect(images == [image.image])
                return sends == 1 ? .failure(code: "model_unavailable", message: message) : .accepted(operationID: id)
            case .setModel(_, _, let id, let model):
                selections.append(model)
                return .accepted(operationID: id)
            default: return .snapshot(value: value)
            }
        }, listModels: { ModelCatalog(ModelCatalogFixture.entries) }, retainedInput: input))
        try await eventuallyOnMain("composer ready") { window.layout(); return store.ready && input.available }
        try window.press("Send")
        try await eventuallyOnMain("model rejection displayed") { window.layout(); return store.modelUnavailable && !store.busy }
        #expect(store.draft == "Please update the design")
        #expect(store.attachedFiles.map(\.name) == ["notes.md"])
        #expect(input.attachments.images == [image.image])
        #expect(ControlPress.undersized(ControlPress.controls(in: window.host).filter { $0.label == "Choose model" }, minimum: .desktop).isEmpty)
        try window.press("Choose model")
        try await eventuallyOnMain("model picker to open") {
            window.layout()
            return ControlPress.controls(in: window.host).contains { $0.label?.contains("claude-opus-4-5") == true }
        }
        let chosen = try #require(ControlPress.controls(in: window.host).first { $0.label?.contains("claude-opus-4-5") == true && $0.role == ControlRole.button })
        try window.press(try #require(chosen.label))
        try await eventuallyOnMain("same model reselected") { window.layout(); return selections == [snapshot.model] && !store.busy }
        #expect(store.notice == nil && !store.modelUnavailable)
        try window.press("Send")
        try await eventuallyOnMain("retry acknowledged") { window.layout(); return sends == 2 && input.attachments.images.isEmpty }
        #expect(store.draft.isEmpty && store.attachedFiles.isEmpty)
    }
}

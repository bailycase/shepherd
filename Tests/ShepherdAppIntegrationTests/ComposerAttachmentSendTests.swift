import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Composer attachment acknowledgement", .mainActorExclusive)
@MainActor
struct ComposerAttachmentSendTests {
    @Test(arguments: [true, false])
    func aDelayedSendConsumesOnlyAcknowledgedAttachments(accepted: Bool) async throws {
        let store = NativeThreadStore()
        let input = ThreadInput()
        var snapshot = ComposerThread.snapshot(messages: 0, commands: [])
        snapshot.supportedActions.append("sendImages")
        let sent = ImageAttachment(name: "sent.png", image: NativeImage(mimeType: "image/png", data: Data([1, 2, 3])))
        let later = ImageAttachment(name: "later.png", image: NativeImage(mimeType: "image/png", data: Data([4, 5, 6])))
        input.attachments.add([(sent.name, sent)])
        store.draft = "send this image"
        var reply: CheckedContinuation<NativeThreadResult, Never>?
        var submitted: [NativeImage]?
        var operation: UUID?
        let window = OffscreenWindow(size: CGSize(width: 800, height: 500))
        defer {
            reply?.resume(returning: .failure(code: "testEnded", message: "test ended"))
            store.stop()
            window.close()
        }
        window.show(ThreadView(store: store, active: true, isFocused: false, request: { request in
            if case let .send(_, _, id, text, _, images, _, _, _) = request {
                #expect(text == "send this image")
                submitted = images
                operation = id
                return await withCheckedContinuation { reply = $0 }
            }
            return .snapshot(value: snapshot)
        }, listModels: { .empty }, retainedInput: input))
        func monitor(_ view: NSView) -> ComposerKeyMonitor? {
            if let reader = view as? ComposerWindowReader.Reader { return reader.monitor }
            return view.subviews.lazy.compactMap(monitor).first
        }
        try await eventuallyOnMain("composer to accept a send") {
            window.layout()
            return store.ready && input.available && monitor(window.host)?.accepts() == true
        }
        let keyMonitor = try #require(monitor(window.host))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(keyMonitor.handle(event))
        try await eventuallyOnMain("real composer send to await acknowledgement") { reply != nil }
        #expect(submitted == [sent.image])
        #expect(input.attachments.ids == [sent.id])
        input.attachments.add([(later.name, later)])
        let pending = try #require(reply)
        reply = nil
        pending.resume(returning: accepted ? .accepted(operationID: try #require(operation))
                       : .failure(code: "refused", message: "send refused"))
        try await eventuallyOnMain("send acknowledgement to finish") {
            !store.busy && (accepted ? input.attachments.ids == [later.id] : store.notice == "send refused")
        }
        #expect(input.attachments.ids == (accepted ? [later.id] : [sent.id, later.id]))
        #expect(input.attachments.images == (accepted ? [later.image] : [sent.image, later.image]))
    }
}

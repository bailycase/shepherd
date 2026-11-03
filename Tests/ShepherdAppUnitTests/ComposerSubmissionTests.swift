import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// A send's words and images leave the composer when the store captures them, not before; a
/// refusal comes back only into an empty composer; an unknown outcome is never restored or retried.
@Suite("Composer submissions", .timeLimit(.minutes(1)))
@MainActor
struct ComposerSubmissionTests {
    /// The host: serves a snapshot, and answers each send as the test says, holding it until released.
    @MainActor final class Host {
        enum Answer { case refuse, unknown, accept }
        var answer: Answer = .refuse
        var hold: CheckedContinuation<Void, Never>?
        var holding = false
        var sends = 0
        let snapshot = NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false,
                                            supportedActions: ["send", "sendImages"], dialogsSupported: true, dialogs: [],
                                            messages: [], provisional: [], clipped: false)

        func request(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            guard case .send = request else { return .snapshot(value: snapshot) }
            sends += 1
            if holding { await withCheckedContinuation { hold = $0 } }
            switch answer {
            case .refuse: return .failure(code: "refused", message: "The agent refused it.")
            case .unknown: throw CancellationError()
            case .accept:
                guard case .send(_, _, let id, _, _, _, _, _, _) = request else { return .snapshot(value: snapshot) }
                return .accepted(operationID: id)
            }
        }
    }

    private func ready(_ host: Host) async -> (NativeThreadStore, Task<Void, Never>) {
        let store = NativeThreadStore(startingLimit: .seconds(60)) { _ in
            let (never, _) = AsyncStream<Void>.makeStream()
            for await _ in never {}
            throw CancellationError()
        }
        let loop = Task { await store.run(request: { try await host.request($0) }) }
        while !store.ready {
            await withCheckedContinuation { changed in
                withObservationTracking { _ = store.ready } onChange: { changed.resume() }
            }
        }
        return (store, loop)
    }

    private func image(_ name: String) -> ImageAttachment {
        ImageAttachment(name: name, image: NativeImage(mimeType: "image/png", data: Data(name.utf8), name: name))
    }

    @Test func capturedImagesLeaveTheComposerAndImagesAddedMeanwhileStay() async {
        let host = Host()
        let (store, loop) = await ready(host)
        defer { loop.cancel() }
        let input = ThreadInput()
        input.attachments.add([("a.png", image("a.png"))])
        store.draft = "look at this"
        host.holding = true
        let send = Task { await ComposerImageCapture.send(store: store, input: input, delivery: .followUp) }
        // Captured: the words and the image are the store's now, shown as sending.
        while store.submissions.isEmpty || !input.attachments.isEmpty {
            await withCheckedContinuation { changed in
                withObservationTracking { _ = store.submissions; _ = input.attachments } onChange: { changed.resume() }
            }
        }
        #expect(store.draft.isEmpty)
        #expect(store.submissions.first?.state == .sending)
        #expect(ThreadSubmissions.note(.sending, restorable: false) == "Sending…")
        input.attachments.add([("b.png", image("b.png"))])
        host.hold?.resume()
        #expect(await send.value == false)
        #expect(input.attachments.items.map(\.name) == ["b.png"], "an image added while it was sending stays")
        let failed = try! #require(store.submissions.first)
        #expect(failed.state == .failed && failed.images.map(\.name) == ["a.png"])

        // Not over the new image, nor over new words.
        #expect(!ThreadSubmissions.canRestore(failed, store: store, input: input))
        input.attachments.removeAll()
        store.draft = "new words"
        #expect(!ThreadSubmissions.canRestore(failed, store: store, input: input))
        ThreadSubmissions.restore(failed.id, store: store, input: input)
        #expect(store.draft == "new words" && store.submissions.count == 1, "nothing typed since is overwritten")
        store.draft = ""
        ThreadSubmissions.restore(failed.id, store: store, input: input)
        #expect(store.draft == "look at this")
        #expect(input.attachments.items.map(\.name) == ["a.png"])
        #expect(store.submissions.isEmpty)
    }

    @Test func anUnknownOutcomeIsNeverRestoredOnlyDiscardedHere() async {
        let host = Host()
        host.answer = .unknown
        let (store, loop) = await ready(host)
        defer { loop.cancel() }
        let input = ThreadInput()
        store.draft = "maybe sent"
        await ComposerImageCapture.send(store: store, input: input, delivery: .followUp)
        let record = try! #require(store.submissions.first)
        #expect(record.state == .uncertain)
        #expect(!ThreadSubmissions.canRestore(record, store: store, input: input))
        ThreadSubmissions.restore(record.id, store: store, input: input)
        #expect(store.draft.isEmpty && store.submissions.count == 1)
        let sends = host.sends
        #expect(store.discardSubmission(record.id))
        #expect(host.sends == sends, "discarding cancels and resends nothing")
    }

    @Test func aSendTheStoreRefusesToCaptureKeepsTheComposerWhole() async {
        let host = Host()
        let (store, loop) = await ready(host)
        defer { loop.cancel() }
        let input = ThreadInput()
        // Unknown outcomes stay in the thread (a refusal would come straight back to the composer).
        host.answer = .unknown
        for index in 0..<NativeThreadStore.maximumRetainedSubmissions {
            store.draft = "refused \(index)"
            await ComposerImageCapture.send(store: store, input: input, delivery: .followUp)
        }
        #expect(store.submissions.count == NativeThreadStore.maximumRetainedSubmissions)
        host.answer = .refuse
        input.attachments.add([("kept.png", image("kept.png"))])
        store.draft = "one more"
        let sends = host.sends
        #expect(await ComposerImageCapture.send(store: store, input: input, delivery: .followUp) == false)
        #expect(host.sends == sends)
        #expect(store.draft == "one more")
        #expect(input.attachments.items.map(\.name) == ["kept.png"], "nothing captured: the images stay")
    }
}

extension ComposerSubmissionTests {
    /// A refusal with nothing typed or added since comes straight back into the composer, words, files and images.
    @Test func aRefusalComesBackIntoAnUntouchedComposer() async {
        let host = Host()
        let (store, loop) = await ready(host)
        defer { loop.cancel() }
        let input = ThreadInput()
        input.attachments.add([("a.png", image("a.png"))])
        store.draft = "refused"
        store.attach(files: [NativeAttachedFile(name: "notes.md", path: "/tmp/notes.md")])
        #expect(await ComposerImageCapture.send(store: store, input: input, delivery: .followUp) == false)
        #expect(store.draft == "refused")
        #expect(store.attachedFiles.map(\.name) == ["notes.md"])
        #expect(input.attachments.items.map(\.name) == ["a.png"])
        #expect(store.submissions.isEmpty)

        // Sent again and accepted: the restored images leave the composer with it.
        host.answer = .accept
        #expect(await ComposerImageCapture.send(store: store, input: input, delivery: .followUp))
        #expect(input.attachments.isEmpty)
        #expect(store.draft.isEmpty && store.attachedFiles.isEmpty)
    }
}

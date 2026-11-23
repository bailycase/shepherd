import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Sends the store captured and the host did not accept, at the thread's tail in the held
/// message style (a pending bubble with its note under it). A send still waiting ("Sending…") is a row of the
/// transcript itself (`NativeThreadStore.rows`), the turn its accepted echo and the host's message then keep:
///
/// - failed (the host refused it): Restore puts the words, files, references, elements and
///   images back in the composer, only when the composer is empty so nothing typed since is
///   overwritten; Discard lets it go;
/// - uncertain (the outcome is unknown, or captured before the app last quit): never restored or
///   retried, since it may have arrived; Copy text puts its words on the clipboard, and Discard
///   only forgets it here and cancels nothing on the host.
struct ThreadSubmissions: View {
    let store: NativeThreadStore
    let input: ThreadInput

    var body: some View {
        // A send still waiting for the host is in the transcript itself (its row says "Sending…"); only its outcomes are here.
        ForEach(store.submissions.filter { $0.state != .sending }) { submission in
            SubmissionRow(submission: submission, restorable: Self.canRestore(submission, store: store, input: input),
                          discardable: store.canDiscardSubmission(submission.id),
                          restore: { Self.restore(submission.id, store: store, input: input) },
                          discard: { store.discardSubmission(submission.id) })
        }
    }

    /// A refused send goes back only into an empty composer: no words, attachments or images added since.
    static func canRestore(_ submission: NativeThreadSubmission, store: NativeThreadStore, input: ThreadInput) -> Bool {
        submission.state == .failed && !store.hasDraft && input.attachments.isEmpty && input.preparingImages == 0
    }

    static func restore(_ id: UUID, store: NativeThreadStore, input: ThreadInput) {
        guard input.attachments.isEmpty, input.preparingImages == 0, let restored = store.restoreSubmission(id) else { return }
        // Back at once, in order and within the limits they were sent under; their thumbnails decode off the main actor.
        let attachments = restored.images.map { ImageAttachment(name: $0.name ?? "Image", image: $0) }
        input.attachments.add(attachments.map { ($0.name, $0) }, clearingError: false)
        input.focus()
        let pixels = ThreadImageLoad.thumbnailPixels
        for attachment in attachments {
            let data = attachment.image.data
            Task {
                let decoded = await Task.detached(priority: .userInitiated) { ViewerImage.decodedThumbnail(data, longestSide: pixels) }.value
                guard let decoded else { return }
                input.attachments.setThumbnail(Image(nsImage: NSImage(cgImage: decoded.image, size: decoded.size)), for: attachment.id)
            }
        }
    }

    static func note(_ state: NativeThreadSubmission.State, restorable: Bool) -> String {
        switch state {
        case .sending: NativeThreadSubmission.sendingNote
        case .failed: restorable ? "Not sent. Restore it to edit and send again." : "Not sent. Clear the composer to restore it."
        case .uncertain: "Delivery unknown. It may have reached the agent; check the thread before sending it again."
        }
    }
}

private struct SubmissionRow: View {
    let submission: NativeThreadSubmission
    let restorable: Bool
    let discardable: Bool
    let restore: () -> Void
    let discard: () -> Void
    @Environment(\.shUserBubbleMetrics) private var bubbleMetrics

    var body: some View {
        VStack(alignment: .trailing, spacing: SH.Space.s) {
            UserTurn(bubbles: [.init(text: submission.typed, images: submission.images.count, caption: nil, pending: true)],
                     note: ThreadSubmissions.note(submission.state, restorable: restorable))
                .equatable()
                .environment(\.shUserBubbleMetrics, { var metrics = bubbleMetrics; metrics.overlaysCaption = false; return metrics }())
            if submission.state != .sending {
                HStack(spacing: SH.Space.s) {
                    if submission.state == .failed {
                        Button("Restore to composer", action: restore)
                            .buttonStyle(.sh(.secondary, size: .s))
                            .disabled(!restorable)
                            .shHelp(restorable ? "Put this message back in the composer" : "Clear the composer first")
                    }
                    if submission.state == .uncertain, !submission.typed.isEmpty {
                        // Its words stay reachable without sending anything: copy them, then decide.
                        Button("Copy text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(submission.typed, forType: .string)
                        }
                        .buttonStyle(.sh(.ghost, size: .s))
                        .shHelp("Copy the words. Nothing is sent.")
                    }
                    Button("Discard", action: discard)
                        .buttonStyle(.sh(.ghost, size: .s))
                        .disabled(!discardable)
                        .shHelp(submission.state == .uncertain ? "Forget it here. Nothing is cancelled on the agent." : "Forget this message")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The composer's side of a send. Its images leave the composer once the store has captured them
/// with the words (shown as sending), not at acceptance, and not at all when the store refused to
/// capture them (a full recovery budget, no connection); images added while it waits stay. A
/// refusal comes straight back into the composer when nothing was typed or added since (as a
/// refused send always has); otherwise it waits in the thread to be restored or discarded. An
/// unknown outcome stays there, never restored or retried.
@MainActor
enum ComposerImageCapture {
    /// The composer's send: the draft and the images on the card now. Returns whether the host accepted it.
    @discardableResult
    static func send(store: NativeThreadStore, input: ThreadInput, delivery: NativeThreadDelivery) async -> Bool {
        // An image still being read belongs to this message: Send waits for it (`Composer.canSend`).
        guard input.preparingImages == 0 else { return false }
        let images = input.attachments.images
        let submitted = input.attachments.ids
        var captured: UUID?
        let accepted = await store.send(images: images, delivery: delivery) {
            // The store just appended this send. A host without image support captures only text.
            guard let submission = store.submissions.last else { return }
            captured = submission.id
            if !submission.images.isEmpty {
                for id in submitted { input.attachments.remove(id) }
            }
            if input.attachments.isEmpty { input.attachments.clearError() }
        }
        if !accepted, let captured {
            // Restore still requires a settled refusal and an empty composer.
            ThreadSubmissions.restore(captured, store: store, input: input)
        }
        return accepted
    }
}

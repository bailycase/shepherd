import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Sends the store has captured but the host has not accepted, at the thread's tail in the held
/// message style (a pending bubble with its note under it):
///
/// - sending: "Sending…", nothing to do yet;
/// - failed (the host refused it): Restore puts the words, files, references, elements and
///   images back in the composer, only when the composer is empty so nothing typed since is
///   overwritten; Discard lets it go;
/// - uncertain (the outcome is unknown): never restored or retried, since it may have arrived;
///   Discard only forgets it here and cancels nothing on the host.
struct ThreadSubmissions: View {
    let store: NativeThreadStore
    let input: ThreadInput

    var body: some View {
        ForEach(store.submissions) { submission in
            SubmissionRow(submission: submission, restorable: Self.canRestore(submission, store: store, input: input),
                          discardable: store.canDiscardSubmission(submission.id),
                          restore: { Self.restore(submission.id, store: store, input: input) },
                          discard: { store.discardSubmission(submission.id) })
        }
    }

    /// A refused send goes back only into an empty composer: no words, attachments or images added since.
    static func canRestore(_ submission: NativeThreadSubmission, store: NativeThreadStore, input: ThreadInput) -> Bool {
        submission.state == .failed && !store.hasDraft && input.attachments.isEmpty
    }

    static func restore(_ id: UUID, store: NativeThreadStore, input: ThreadInput) {
        guard input.attachments.isEmpty, let restored = store.restoreSubmission(id) else { return }
        // Back at once, in order and within the limits they were sent under; their thumbnails decode off the main actor.
        let attachments = restored.images.map { ImageAttachment(name: $0.name ?? "Image", image: $0) }
        input.attachments.add(attachments.map { ($0.name, $0) })
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
        case .sending: "Sending…"
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
        let send = Send(store: store, input: input)
        send.watch()
        let accepted = await store.send(images: send.images, delivery: delivery)
        // Accepted: captured, even if its record came and went before the watch looked.
        send.done = true
        if accepted { send.accepted() } else { send.step() }
        return accepted
    }

    @MainActor final class Send {
        let store: NativeThreadStore
        let input: ThreadInput
        let images: [NativeImage]
        private let submitted: [UUID]
        private let typed: String
        private let before: Set<UUID>
        /// The record the store captured for this send, once seen.
        private var record: UUID?
        var done = false
        private var finished = false

        init(store: NativeThreadStore, input: ThreadInput) {
            self.store = store
            self.input = input
            images = input.attachments.images
            submitted = input.attachments.ids
            typed = store.draft
            before = Set(store.submissions.map(\.id))
        }

        func watch() {
            guard !finished else { return }
            withObservationTracking { step() } onChange: { [weak self] in
                Task { @MainActor in self?.watch() }
            }
        }

        func accepted() {
            guard !finished else { return }
            finished = true
            for id in submitted { input.attachments.remove(id) }
        }

        /// One look at the store's records; idempotent.
        func step() {
            guard !finished else { return }
            let current = record.flatMap { id in store.submissions.first { $0.id == id } }
                ?? store.submissions.first { !before.contains($0.id) && $0.typed == typed && $0.images == images }
            guard let current else {
                // Accepted (its record gone) or never captured: either way this send is over once it returned.
                if record != nil || done {
                    if record != nil { for id in submitted { input.attachments.remove(id) } }
                    finished = true
                }
                return
            }
            if record == nil {
                record = current.id
                for id in submitted { input.attachments.remove(id) }
            }
            switch current.state {
            case .sending: break
            case .failed:
                finished = true
                if ThreadSubmissions.canRestore(current, store: store, input: input) {
                    ThreadSubmissions.restore(current.id, store: store, input: input)
                }
            case .uncertain: finished = true
            }
        }
    }
}

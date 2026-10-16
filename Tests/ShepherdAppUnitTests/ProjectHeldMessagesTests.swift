import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// A Project's accepted messages the transcript has not taken in: waiting ones are the composer's shared Up next (read-only, from
/// the owner's queue), outcomes stay in the transcript with their note, and each message is drawn in exactly one place.
@Suite("Project held messages")
@MainActor
struct ProjectHeldMessagesTests {
    private func message(_ text: String, _ phase: ProjectMessage.Phase, images: [ProjectInputImage]? = nil) -> ProjectMessage {
        ProjectMessage(id: UUID(), text: text, phase: phase, images: images)
    }

    /// Queued is pending whatever the coordinator is doing (busy, idle, launching, or the Project paused): the owner holds it, so it is
    /// never drawn as sent. Only the Paused tooltip depends on the pause.
    @Test(arguments: [false, true])
    func aQueuedMessageWaitsInUpNextNeverAsASentBubble(paused: Bool) {
        let queued = message("next", .queued)
        let held = ProjectHeldMessages.held(messages: [queued], paused: paused, consumed: [])
        let upNext = ProjectHeldMessages.upNext(held)
        #expect(upNext.queue.map(\.id) == [queued.id] && upNext.queue.map(\.state) == [.queued])
        #expect(held.filter { !$0.waiting }.isEmpty, "nothing for the transcript")
        #expect(upNext.paused == (paused ? "Sends when the project resumes" : nil))
    }

    /// Handed off (`delivering`) but pi's own pending row is not here yet: still Up next. Once the transcript holds the delivery's
    /// operation (the native pending row, then the saved message), it is the transcript's alone.
    @Test func aHandoffLeavesUpNextOnlyWhenTheTranscriptHoldsItsOperation() {
        var sending = message("go", .delivering)
        let delivery = UUID()
        sending.nativeDeliveryID = delivery
        #expect(ProjectHeldMessages.upNext(ProjectHeldMessages.held(messages: [sending], paused: false, consumed: [])).queue.map(\.id) == [sending.id])
        for consumed in [delivery, sending.id] {
            let held = ProjectHeldMessages.held(messages: [sending], paused: false, consumed: [consumed])
            #expect(held.isEmpty, "drawn once, by the transcript")
        }
        var delivered = sending
        delivered.phase = .delivered
        #expect(ProjectHeldMessages.held(messages: [delivered], paused: false, consumed: []).isEmpty, "delivered is the transcript's")
    }

    /// A cancelled handoff returns to the queue under a new native delivery id. The first attempt went as the message's own id; while
    /// that attempt's stale pending row is still in the transcript, the echo is its one representation. Once the row goes (the host
    /// drops a cancelled send's row), it waits in Up next again under its public identity, and a stale echo of a later cancelled
    /// attempt never hides it once the owner has moved to a newer delivery.
    @Test func aCancelledHandoffIsQueuedAgainUnderItsNewDelivery() {
        var requeued = message("again", .queued)
        let second = UUID()
        requeued.nativeDeliveryID = UUID()
        let echoed = ProjectHeldMessages.held(messages: [requeued], paused: false, consumed: [requeued.id])
        #expect(echoed.isEmpty, "the first attempt's echo is still the transcript's: drawn once")
        let upNext = ProjectHeldMessages.upNext(ProjectHeldMessages.held(messages: [requeued], paused: false, consumed: []))
        #expect(upNext.queue.map(\.id) == [requeued.id] && upNext.queue.map(\.state) == [.queued], "keeps its public identity, in its place")
        #expect(ProjectHeldMessages.upNext(ProjectHeldMessages.held(messages: [requeued], paused: false, consumed: [second])).queue.count == 1,
                "an echo of a delivery id the owner no longer holds consumes nothing")
    }

    /// A remote owner's record reaches the viewer with the descriptors it pushed: image names, no bytes. An older owner's record has no
    /// delivery id and no image list; it is matched by its own id and drawn the same way. Order is the owner's.
    @Test func aRemoteOrOlderOwnersRecordDrawsTheSame() {
        var old = message("from an older owner", .queued)
        old.images = nil
        old.nativeDeliveryID = nil
        let named = message("with a picture", .delivering,
                            images: [ProjectInputImage(id: UUID(), mimeType: "image/png", name: nil, byteCount: 5)])
        let held = ProjectHeldMessages.held(messages: [old, named], paused: false, consumed: [])
        let upNext = ProjectHeldMessages.upNext(held)
        #expect(upNext.queue.map(\.text) == ["from an older owner", "with a picture"])
        #expect(upNext.queue.map { $0.images.map(\.name) } == [[], [nil]], "an unnamed image is still counted")
        #expect(ProjectHeldMessages.held(messages: [old], paused: false, consumed: [old.id]).isEmpty, "matched by its own id")
    }

    /// What is drawn is the person's words, whether the owner marked them human-submitted (a current owner) or not (a legacy record);
    /// a worker report is filtered by its `source`, never by a missing flag.
    @Test func humanSubmittedDoesNotHideALegacyMessage() {
        var marked = message("marked", .queued)
        marked.humanSubmitted = true
        let legacy = message("legacy", .queued)
        #expect(ProjectHeldMessages.upNext(ProjectHeldMessages.held(messages: [marked, legacy], paused: true, consumed: [])).queue.map(\.text)
                == ["marked", "legacy"])
    }

    /// Unknown and failed are outcomes, not waiting: they stay in the transcript with their own note (a refusal's detail, never an
    /// unknown's), keep their image count, and are never put back in Up next as if they would still send.
    @Test func undeliveredMessagesStayExplicitInTheTranscript() {
        var failed = message("refused", .failed, images: [ProjectInputImage(id: UUID(), mimeType: "image/png", name: "a.png", byteCount: 1)])
        failed.failureDetail = "No API key"
        var unknown = message("lost", .unknown)
        unknown.failureDetail = "must never show"
        let held = ProjectHeldMessages.held(messages: [message("q", .queued), failed, unknown], paused: false, consumed: [])
        #expect(ProjectHeldMessages.upNext(held).queue.map(\.text) == ["q"])
        let outcomes = held.filter { !$0.waiting }
        #expect(outcomes.map(\.note) == ["Not delivered. No API key. Send it again to retry.", "Delivery unconfirmed. Send it again to retry."])
        #expect(outcomes.map(\.images.count) == [1, 0])
    }

    /// The owner's images reach the shared stack by name; this Mac has no bytes for them, so the rows draw named chips, no thumbnails.
    @Test func theSharedStackNamesTheOwnersImagesWithoutBytes() {
        let images = [ProjectInputImage(id: UUID(), mimeType: "image/png", name: "plan.png", byteCount: 3),
                      ProjectInputImage(id: UUID(), mimeType: "image/jpeg", byteCount: 3)]
        let first = message("first", .queued, images: images), second = message("second", .queued)
        let upNext = ProjectHeldMessages.upNext(ProjectHeldMessages.held(messages: [first, second], paused: true, consumed: []))
        let state = QueueStackState()
        state.update(upNext.queue)
        #expect(state.rows.map(\.kind) == [.queued(number: 1), .queued(number: 2)], "numbered in the owner's order")
        #expect(state.rows.first?.attachments.map(\.name) == ["plan.png", "Image"])
        #expect(state.rows.first?.attachments.allSatisfy { $0.thumbnail == nil } == true)
        #expect(state.count == 2 && state.queuedCount == 2)
    }

    /// A worker report is the runtime's own wake-up, never the person's message, so it is in neither place.
    @Test func aWorkerReportIsNeverDrawn() {
        let report = ProjectMessage(id: UUID(), text: "report", phase: .queued,
                                    source: ProjectEventSource(kind: .settled, taskID: ProjectTaskID(), operationID: UUID(), workerAgentID: AgentID(), sessionID: nil))
        #expect(ProjectHeldMessages.held(messages: [report], paused: false, consumed: []).isEmpty)
    }
}

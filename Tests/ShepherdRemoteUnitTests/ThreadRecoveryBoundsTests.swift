import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ThreadRecoveryBoundsTests {
    typealias F = Fixture

    @Test func payloadAccountingSaturatesBeforeOverflowOrAdmission() {
        let budget = NativeThreadStore.maximumRetainedSubmissionBytes
        #expect(NativeThreadSubmission.accountedPayloadBytes(0, addingTo: 128) == 128)
        #expect(NativeThreadSubmission.accountedPayloadBytes(3, unitBytes: 8, addingTo: 128) == 152)
        #expect(NativeThreadSubmission.accountedPayloadBytes(budget - 128, addingTo: 128) == budget)
        #expect(NativeThreadSubmission.accountedPayloadBytes(budget, addingTo: 128) == budget + 1)
        #expect(NativeThreadSubmission.accountedPayloadBytes(Int.max, addingTo: 1) == budget + 1)
        #expect(NativeThreadSubmission.accountedPayloadBytes(Int.max, unitBytes: 8) == budget + 1)
        #expect(NativeThreadSubmission.accountedPayloadBytes(1, addingTo: budget + 1) == budget + 1)
    }

    @Test(arguments: [false, true])
    func explicitUnknownOutcomesNeverBecomeRetryable(rejectedError: Bool) async throws {
        let host = FakeHost(F.snapshot())
        host.action = { _ in
            if rejectedError { throw RemoteHostClientError.rejected(code: "outcome_unknown", message: "Check the thread") }
            return .failure(code: "outcome_unknown", message: "Check the thread")
        }
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        store.draft = "possibly accepted"
        #expect(await store.send(delivery: .followUp) == false)
        let record = try #require(store.submissions.first)
        #expect(record.state == .uncertain && record.typed == "possibly accepted")
        #expect(store.restoreSubmission(record.id) == nil && store.draft.isEmpty)
        #expect(await store.send(delivery: .followUp) == false)
        #expect(host.actions.count == 1, "neither restoration nor an empty send may resend uncertain content")
        store.suspend()
        #expect(!store.canReleaseHistory)
        store.draft = "new work"
        let requests = host.requests
        #expect(store.discardSubmission(record.id))
        #expect(!store.discardSubmission(record.id))
        #expect(store.draft == "new work" && store.retainedSubmissionBytes == 0)
        #expect(host.requests == requests, "disposal is local acknowledgment, never a remote action")
        #expect(store.canReleaseHistory)
        store.release()
        #expect(store.snapshot == nil && store.draft == "new work")
    }

    @Test func countAdmissionKeepsEveryUnresolvedImageAndTheUnsentDraft() async throws {
        let host = FakeHost(F.snapshot(actions: ["send", "sendImages", "designReferences", "browserElements"]))
        var attempts = 0
        host.action = { _ in
            attempts += 1
            return .failure(code: attempts.isMultiple(of: 2) ? "outcome_unknown" : "busy", message: "not settled")
        }
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        let image = NativeImage(mimeType: "image/png", data: Data(repeating: 7, count: 1_024), name: "kept")
        for index in 0..<NativeThreadStore.maximumRetainedSubmissions {
            store.draft = "submission \(index)"
            #expect(await store.send(images: [image], delivery: .followUp) == false)
            #expect(store.submissions.count == index + 1)
            #expect(store.submissions.last?.images == [image])
        }
        let records = store.submissions
        let bytes = records.reduce(0) { $0 + $1.payloadBytes }
        #expect(store.retainedSubmissionBytes == bytes)
        #expect(records.map(\.state).contains(.failed) && records.map(\.state).contains(.uncertain))
        store.draft = "new draft must stay"
        let file = NativeAttachedFile(name: "keep", path: "/tmp/keep")
        store.attach(files: [file])
        let reference = NativeAttachedReference(reference: try #require(DesignReference(string: "shepherd-design-ref://local/d1/A.dc.html")), label: "A")
        #expect(store.attach(reference: reference))
        #expect(store.attach(element: BrowserElement(page: "page", selector: "button", label: "button", width: 1, height: 1, html: "<button/>")))
        let elements = store.attachedElements
        let requests = host.requests.count
        for _ in 0..<3 {
            #expect(await store.send(images: [image], delivery: .followUp) == false)
            #expect(store.submissions == records && store.retainedSubmissionBytes == bytes)
            #expect(store.draft == "new draft must stay" && store.attachedFiles == [file])
            #expect(store.attachedReferences == [reference] && store.attachedElements == elements)
            #expect(host.requests.count == requests, "admission refuses before any send or refresh")
        }
        #expect(store.notice?.contains("recovery limit") == true)
        #expect(store.discardSubmission(records[0].id))
        #expect(store.retainedSubmissionBytes == bytes - records[0].payloadBytes)
        #expect(store.submissions == Array(records.dropFirst()))
        #expect(store.draft == "new draft must stay" && host.requests.count == requests)
        #expect(await store.send(images: [image], delivery: .followUp) == false)
        #expect(attempts == NativeThreadStore.maximumRetainedSubmissions + 1)
        let admitted = try #require(store.submissions.last)
        #expect(admitted.typed == "new draft must stay" && admitted.images == [image])
        #expect(admitted.files == [file] && admitted.references == [reference] && admitted.elements == elements)
        #expect(store.submissions.count == NativeThreadStore.maximumRetainedSubmissions)
        store.suspend()
        #expect(!store.canReleaseHistory)
        store.draft = "another draft"
        for record in store.submissions { #expect(store.discardSubmission(record.id)) }
        #expect(store.retainedSubmissionBytes == 0 && store.canReleaseHistory && store.draft == "another draft")
    }

    @Test(arguments: ["busy", "outcome_unknown"])
    func payloadAdmissionAcceptsTheExactBudgetButNotOneByteMore(_ code: String) async throws {
        let host = FakeHost(F.snapshot(actions: ["send", "sendImages"]))
        host.action = { _ in .failure(code: code, message: "not settled") }
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        let image = NativeImage(mimeType: "image/png", data: Data(repeating: 1, count: 1_024 * 1_024), name: "kept")
        for index in 0..<4 {
            store.draft = "images \(index)"
            #expect(await store.send(images: [image, image, image], delivery: .followUp) == false)
        }
        let records = store.submissions
        let base = NativeThreadSubmission(id: UUID(), typed: "", files: [], references: [], elements: [],
                                          images: [image], delivery: .followUp, state: .sending).payloadBytes
        let remainingText = NativeThreadStore.maximumRetainedSubmissionBytes - store.retainedSubmissionBytes - base
        #expect(remainingText > 0)
        store.draft = String(repeating: "x", count: remainingText + 1)
        let requests = host.requests.count
        #expect(await store.send(images: [image], delivery: .followUp) == false)
        #expect(host.requests.count == requests && store.submissions == records)
        #expect(store.draft.utf8.count == remainingText + 1, "one byte over must remain completely recoverable in the composer")
        store.draft.removeLast()
        #expect(await store.send(images: [image], delivery: .followUp) == false)
        #expect(host.actions.count == 5 && store.submissions.count == 5)
        #expect(store.retainedSubmissionBytes == NativeThreadStore.maximumRetainedSubmissionBytes)
        let last = try #require(store.submissions.last)
        #expect(last.typed.utf8.count == remainingText && last.images == [image])
        store.draft = "é"
        #expect(await store.send(delivery: .followUp) == false)
        #expect(host.actions.count == 5 && store.draft == "é")
        #expect(store.discardSubmission(records[0].id))
        #expect(store.retainedSubmissionBytes == NativeThreadStore.maximumRetainedSubmissionBytes - records[0].payloadBytes)
        #expect(store.submissions.last == last && store.draft == "é")
        store.draft = ""
        if code == "busy" {
            #expect(store.restoreSubmission(last.id) == last)
            #expect(store.draft == last.typed)
            #expect(store.retainedSubmissionBytes == store.submissions.reduce(0) { $0 + $1.payloadBytes })
        } else {
            #expect(store.restoreSubmission(last.id) == nil)
        }
    }

    @Test func suspensionDoesNotMakeAnOutstandingSendDisposable() async throws {
        let host = FakeHost(F.snapshot()), gate = FirstPullGate()
        let store = manualStore()
        let loop = Task {
            await store.run { request in
                if case .send = request {
                    gate.asked = true
                    await until { !gate.held }
                    return .failure(code: "outcome_unknown", message: "not settled")
                }
                return try host.handle(request)
            }
        }
        defer { gate.held = false; loop.cancel(); store.stop() }
        await until { store.ready }
        store.draft = "held"
        let sending = Task { await store.send(delivery: .followUp) }
        await until { gate.asked }
        let id = try #require(store.submissions.first?.id)
        #expect(!store.canDiscardSubmission(id) && !store.discardSubmission(id))
        store.suspend()
        #expect(store.submissions.first?.state == .uncertain)
        #expect(!store.canDiscardSubmission(id) && !store.discardSubmission(id))
        store.draft = "new draft"
        gate.held = false
        #expect(await sending.value == false)
        #expect(store.canDiscardSubmission(id) && store.discardSubmission(id))
        #expect(store.draft == "new draft" && host.actions.isEmpty && store.retainedSubmissionBytes == 0)
        #expect(store.canReleaseHistory)
    }

    @Test func nonCooperativeParsesKeepTheirSlotsAcrossReleaseAndSessionChanges() async {
        let gate = NonCooperativeParseGate()
        defer { gate.release() }
        let store = manualStore()
        store.duringProseParse = { gate.hold() }
        let long = String(repeating: "word ", count: 2_000)
        func snapshot(_ generation: Int) -> NativeThreadSnapshot {
            F.snapshot(generation: "g\(generation)", messages: [
                F.user(id: "u1"), F.assistant(long + "\(generation) first", id: "a1"),
                F.user(id: "u2"), F.assistant(long + "\(generation) last", id: "a2")])
        }
        store.preview(snapshot(0))
        await gate.waitForStarts(2)
        for generation in 1...6 {
            store.release()
            store.preview(snapshot(generation))
            #expect(store.offMainParses == 2, "invalidating results must not free executing worker reservations")
            #expect(gate.started == 2 && gate.active == 2, "the actual synchronous workers ignore cancellation")
        }
        gate.release()
        await store.waitForProse()
        #expect(gate.peak == 2 && gate.started == 4 && gate.active == 0)
        #expect(store.offMainParses == 4 && store.activeProseTasks == 0 && store.mainActorLargeParses == 0)
        #expect(store.snapshot?.generation == "g6")
        let texts = store.rows.compactMap(\.presentation).flatMap(\.items).compactMap { item -> String? in
            guard case .prose(_, let text, let blocks, _) = item else { return nil }
            #expect(blocks == nativeMarkdownParse(text, streaming: false).blocks)
            return text
        }
        #expect(texts == [long + "6 first", long + "6 last"], "only the newest queued generation may publish")
        store.release()
        #expect(store.retainedHistoryBytes == 0)
    }
}

/// Blocks actual detached worker threads without honoring task cancellation. No sleeps or
/// polling: a stream reports entry, and the test explicitly opens the condition gate.
private final class NonCooperativeParseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    private var starts = 0
    private var workers = 0
    private var maximum = 0
    private let events: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation

    init() { (events, continuation) = AsyncStream<Int>.makeStream() }
    var started: Int { condition.withLock { starts } }
    var active: Int { condition.withLock { workers } }
    var peak: Int { condition.withLock { maximum } }

    func hold() {
        condition.lock()
        starts += 1
        workers += 1
        maximum = max(maximum, workers)
        continuation.yield(starts)
        while held { condition.wait() }
        workers -= 1
        condition.unlock()
    }

    func waitForStarts(_ count: Int) async {
        for await value in events { if value >= count { return } }
    }

    func release() {
        condition.withLock { held = false; condition.broadcast() }
    }
}

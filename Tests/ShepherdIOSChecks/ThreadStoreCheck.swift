import Foundation
import ShepherdProtocol
import ShepherdRemote

@main
struct ThreadStoreCheck {
    @MainActor
    static func main() async throws {
        let store = NativeThreadStore()
        var current = try snapshot(ids: ["m3", "m4"], cursor: "m3")
        var requests: [NativeThreadRequest] = []
        var pendingPage: CheckedContinuation<NativeThreadResult, Error>?
        var pendingAction: CheckedContinuation<NativeThreadResult, Error>?
        var pendingRecent: CheckedContinuation<NativeThreadResult, Error>?
        var delayRecent = false
        var failRecent = false
        let run = Task {
            await store.run { request in
                requests.append(request)
                switch request {
                case .snapshot(_, let before, let revision):
                    if failRecent {
                        failRecent = false
                        return .failure(code: "bridge_disconnected", message: "fixture reconnect")
                    }
                    if before != nil {
                        return try await withCheckedThrowingContinuation { pendingPage = $0 }
                    }
                    if delayRecent {
                        delayRecent = false
                        return try await withCheckedThrowingContinuation { pendingRecent = $0 }
                    }
                    if revision == current.revision {
                        return .unchanged(piSessionID: current.piSessionID, generation: current.generation, revision: current.revision)
                    }
                    return .snapshot(value: current)
                default:
                    return try await withCheckedThrowingContinuation { pendingAction = $0 }
                }
            }
        }
        try await wait { store.ready }
        precondition(requests.first == .snapshot())
        precondition(store.pollInterval == .seconds(2))
        await store.refresh()
        precondition(requests.last == .snapshot(expectedSessionID: "session", afterRevision: 1))

        let page = Task { await store.loadOlder() }
        try await wait { pendingPage != nil }
        current = try snapshot(ids: ["m4", "m5"], cursor: "m4", revision: 2, running: true)
        await store.refresh()
        pendingPage!.resume(returning: .snapshot(value: try snapshot(ids: ["m1", "m2", "m3"], revision: 1)))
        pendingPage = nil
        await page.value
        precondition(store.messages.map(\.entryID) == ["m1", "m2", "m3", "m4", "m5"])
        precondition(store.snapshot?.revision == 2 && store.snapshot?.running == true)
        precondition(store.olderCursor == nil && store.pollInterval == .milliseconds(500))
        await store.refresh(fresh: true)
        precondition(store.messages.map(\.entryID) == ["m1", "m2", "m3", "m4", "m5"], "refresh discarded loaded history")
        failRecent = true
        await store.refresh()
        precondition(!store.ready)
        await store.refresh()
        precondition(requests.last == .snapshot(), "bridge reconnect reused stale revision")

        // A newer refresh wins even if an older recent request arrives later.
        delayRecent = true
        let oldRefresh = Task { await store.refresh() }
        try await wait { pendingRecent != nil }
        current.revision = 3
        await store.refresh()
        pendingRecent!.resume(returning: .snapshot(value: try snapshot(ids: ["stale"], revision: 2)))
        pendingRecent = nil
        await oldRefresh.value
        precondition(store.snapshot?.revision == 3 && !store.messages.contains { $0.entryID == "stale" })

        store.draft = "continue"
        store.delivery = .steer
        let send = Task { await store.send() }
        try await wait { pendingAction != nil }
        guard case .send(let session, let generation, let operation, let text, let delivery, _) = requests.last else { fatalError("send missing") }
        precondition(session == "session" && generation == "generation" && text == "continue" && delivery == .steer)
        precondition(store.draft == "continue")
        store.draft = "edited while pending"
        pendingAction!.resume(returning: .accepted(operationID: operation))
        pendingAction = nil
        await send.value
        precondition(store.draft == "edited while pending" && store.sentCount == 1)

        let sendExact = Task { await store.send() }
        try await wait { pendingAction != nil }
        guard case .send(_, _, let exactID, _, _, _) = requests.last else { fatalError("send missing") }
        pendingAction!.resume(returning: .accepted(operationID: exactID))
        pendingAction = nil
        await sendExact.value
        precondition(store.draft.isEmpty && store.sentCount == 2)

        store.draft = "keep on unknown"
        let unknown = Task { await store.send() }
        try await wait { pendingAction != nil }
        pendingAction!.resume(throwing: RemoteHostClientError.outcomeUnknown(message: "test timeout"))
        pendingAction = nil
        await unknown.value
        precondition(store.draft == "keep on unknown" && store.notice?.contains("Nothing will be resent automatically") == true)
        let sendCount = requests.filter { if case .send = $0 { return true }; return false }.count
        await store.refresh()
        precondition(requests.filter { if case .send = $0 { return true }; return false }.count == sendCount)

        // A mismatched acknowledgement cannot clear the draft.
        let mismatch = Task { await store.send() }
        try await wait { pendingAction != nil }
        pendingAction!.resume(returning: .accepted(operationID: UUID()))
        pendingAction = nil
        await mismatch.value
        precondition(store.draft == "keep on unknown" && store.sentCount == 2)

        current = try snapshot(ids: ["new"], cursor: "new", revision: 4, dialogs: true)
        await store.refresh(fresh: true)
        let stalePage = Task { await store.loadOlder() }
        try await wait { pendingPage != nil }
        current.piSessionID = "replacement"
        current.generation = "replacement-generation"
        await store.refresh(fresh: true)
        pendingPage!.resume(returning: .snapshot(value: try snapshot(ids: ["wrong-session"])))
        pendingPage = nil
        await stalePage.value
        precondition(store.messages.map(\.entryID) == ["new"])
        let beforeStaleAnswer = requests.count
        await store.answer(dialogID: "question", sessionID: "session", generation: "generation", answer: .confirm(value: true))
        precondition(requests.count == beforeStaleAnswer)
        for answer in [NativeDialogAnswer.select(value: "yes"), .confirm(value: false), .input(value: ""), .editor(value: "body"), .cancel] {
            let answerTask = Task { await store.answer(dialogID: "question", sessionID: "replacement", generation: "replacement-generation", answer: answer) }
            try await wait { pendingAction != nil }
            guard case .answer(let session, let generation, let id, let dialog, let sentAnswer) = requests.last else { fatalError("answer missing") }
            precondition(session == "replacement" && generation == "replacement-generation" && dialog == "question" && answer == sentAnswer)
            pendingAction!.resume(returning: .accepted(operationID: id))
            pendingAction = nil
            await answerTask.value
        }
        current.dialogs[0].unavailable = "external-editor"
        current.revision += 1
        await store.refresh()
        let beforeUnavailable = requests.count
        await store.answer(dialogID: "question", sessionID: "replacement", generation: "replacement-generation", answer: .cancel)
        precondition(requests.count == beforeUnavailable)

        let abort = Task { await store.abort() }
        try await wait { pendingAction != nil }
        guard case .abort(_, _, let abortID) = requests.last else { fatalError("abort missing") }
        pendingAction!.resume(returning: .accepted(operationID: abortID))
        pendingAction = nil
        await abort.value

        // Leaving during a mutation retains the draft and ignores the late acknowledgement.
        let lateSend = Task { await store.send() }
        try await wait { pendingAction != nil }
        guard case .send(_, _, let lateID, _, _, _) = requests.last else { fatalError("send missing") }
        run.cancel()
        store.stop()
        pendingAction!.resume(returning: .accepted(operationID: lateID))
        pendingAction = nil
        await lateSend.value
        await run.value
        precondition(!store.ready && store.draft == "keep on unknown")
        let stoppedCount = requests.count
        try await Task.sleep(for: .milliseconds(600))
        precondition(requests.count == stoppedCount)

        var reconnectFirst: NativeThreadRequest?
        let reconnect = Task {
            await store.run { request in
                if reconnectFirst == nil { reconnectFirst = request }
                return .snapshot(value: current)
            }
        }
        try await wait { store.ready }
        precondition(reconnectFirst == .snapshot())
        current.messages[0].toolCallID = "call"
        var provisional = current.messages[0]
        provisional.entryID = "provisional:call"
        current.provisional = [provisional, current.messages[0]]
        current.revision += 1
        await store.refresh()
        precondition(store.displayedMessages.map(\.entryID) == ["new"], "duplicate provisional IDs/tool calls")
        reconnect.cancel()
        store.stop()
        await reconnect.value
        try await contextCheck()
        print("PASS: thread revisions, history/live merge, stale responses/session, exact acceptance, edited/unknown drafts, no replay, typed dialogs, external editor, abort, stop/reconnect, context ring and compact")
    }

    /// The context ring the iPad and iPhone composer draws: none from a host that reports no
    /// context, redrawn only when the usage changes, and Compact now as pi's compact.
    @MainActor
    static func contextCheck() async throws {
        let store = NativeThreadStore()
        var current = try snapshot(ids: ["c1"])
        var requests: [NativeThreadRequest] = []
        let run = Task {
            await store.run { request in
                requests.append(request)
                switch request {
                case .snapshot(_, _, let revision):
                    if revision == current.revision {
                        return .unchanged(piSessionID: current.piSessionID, generation: current.generation, revision: current.revision)
                    }
                    return .snapshot(value: current)
                case .compact(_, _, let operationID, _):
                    return .accepted(operationID: operationID)
                default:
                    return .failure(code: "unexpected", message: "fixture")
                }
            }
        }
        try await wait { store.ready }
        precondition(store.contextMeter == nil && store.contextDetails == nil, "a host without context drew a ring")
        await store.compact(instructions: "keep")
        precondition(!requests.contains { if case .compact = $0 { true } else { false } }, "compact sent to a host without it")

        current.revision += 1
        current.supportedActions.append("compact")
        current.context = NativeThreadContext(tokens: 136_000, window: 200_000, autoCompactAt: 183_616, autoCompact: true)
        await store.refresh()
        precondition(store.contextMeter?.ring == .fill(0.68, .warning), "68% is amber: \(String(describing: store.contextMeter))")
        let meter = store.contextMeter

        // A streamed reply changes the thread, not the ring.
        current.revision += 1
        current.messages[0].blocks[0].text += " and more"
        await store.refresh()
        precondition(store.contextMeter == meter)

        // After each accepted action the store pulls the thread again.
        func lastCompact() -> NativeThreadRequest? { requests.last { if case .compact = $0 { true } else { false } } }
        await store.compact(instructions: "  Keep the preview findings\n")
        guard case .compact(let session, _, _, let instructions) = lastCompact() else { fatalError("compact missing") }
        precondition(session == "session" && instructions == "Keep the preview findings", "what to keep: \(String(describing: instructions))")
        try await wait { store.supports("compact") }
        await store.compact(instructions: "   ")
        precondition(requests.count { if case .compact = $0 { true } else { false } } == 2, "second compact missing")
        guard case .compact(_, _, _, let none) = lastCompact() else { fatalError("compact missing") }
        precondition(none == nil, "an empty field sends no instructions")

        run.cancel()
        store.stop()
        await run.value
    }

    static func snapshot(ids: [String], cursor: String? = nil, revision: UInt64 = 1, running: Bool = false, dialogs: Bool = false) throws -> NativeThreadSnapshot {
        var json: [String: Any] = [
            "piSessionID": "session", "generation": "generation", "revision": revision, "running": running,
            "supportedActions": ["send", "abort", "answer"], "dialogsSupported": dialogs,
            "dialogs": dialogs ? [["id": "question", "kind": "confirm", "title": "Proceed?"]] : [],
            "messages": ids.map { ["entryID": $0, "role": "assistant", "blocks": [["kind": "text", "text": $0]], "truncated": false] as [String: Any] },
            "provisional": [], "clipped": false,
        ]
        json["olderCursor"] = cursor
        return try JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("timed out")
    }
}

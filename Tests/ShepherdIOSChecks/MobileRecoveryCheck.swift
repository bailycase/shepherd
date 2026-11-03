import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Unsent messages across a quit (`ThreadRecovery` saved by `ThreadStores`): the real
// NativeThreadStore over a scripted host, and a second ThreadStores over the same defaults as the
// next launch. Built and run by run.sh on macOS.
@main
struct MobileRecoveryCheck {
    @MainActor
    static func main() async throws {
        let defaults = UserDefaults(suiteName: "shepherd-recovery-check-\(UUID())")!
        let host = UUID()
        func ref(_ name: String) -> AgentRef { AgentRef(host: host, agent: AgentID(rawValue: name)) }

        // Held at admission, then the app quits: the text is saved as unknown, never restorable, never sent again.
        do {
            let threads = ThreadStores(defaults: defaults)
            let script = Script()
            let store = threads.store(for: ref("held"))
            let run = Task { await store.run(request: script.request) }
            try await wait("ready") { store.ready }
            store.draft = "hello there"
            let send = Task { await store.send() }
            try await wait("send held") { script.held != nil }
            try await wait("saved while held") { ThreadRecovery.load(ref("held"), defaults: defaults).map(\.typed) == ["hello there"] }
            check(store.draft.isEmpty && defaults.string(forKey: NativeDraftKey.text(host: host, agent: AgentID(rawValue: "held"))) == nil,
                  "the store took it out of the composer; the draft's own key is untouched")
            let next = ThreadStores(defaults: defaults)
            let relaunched = next.store(for: ref("held"))
            let quiet = Script()
            let again = Task { await relaunched.run(request: quiet.request) }
            try await wait("relaunched ready") { relaunched.ready }
            check(next.recovered[ref("held")]?.map(\.state) == [.uncertain], "a send in flight at quit comes back as unknown")
            check(next.restoreRecovered(next.recovered[ref("held")]![0].id, for: ref("held")) == nil, "an unknown send is never restored")
            try await Task.sleep(for: .milliseconds(300))
            check(!quiet.requests.contains { if case .send = $0 { true } else { false } }, "nor sent again on relaunch")
            // A reconnect of the first launch's store while held: still kept; its later acceptance clears it.
            store.stop()
            let reconnect = Task { await store.run(request: script.request) }
            try await wait("reconnected") { store.ready }
            check(!ThreadRecovery.load(ref("held"), defaults: defaults).isEmpty, "a reconnect keeps the held send saved")
            script.answer(.accepted(operationID: script.heldOperation!))
            await send.value
            try await wait("accepted send is let go") { store.submissions.isEmpty }
            try await wait("and its saved copy") { ThreadRecovery.load(ref("held"), defaults: defaults).isEmpty }
            next.discardRecovered(next.recovered[ref("held")]![0].id, for: ref("held"))
            check(next.recovered[ref("held")] == nil && ThreadRecovery.load(ref("held"), defaults: defaults).isEmpty,
                  "discarding removes the kept copy")
            check(!quiet.requests.contains { if case .send = $0 { true } else { false } }, "discarding sends nothing")
            run.cancel(); reconnect.cancel(); again.cancel()
        }

        // Refused, then a quit: back as the draft only into an empty composer; a new draft is kept apart.
        do {
            let threads = ThreadStores(defaults: defaults)
            let script = Script(refuse: "busy")
            let store = threads.store(for: ref("refused"))
            let run = Task { await store.run(request: script.request) }
            try await wait("ready") { store.ready }
            store.draft = "ship the fix"
            await store.send(images: [NativeImage(mimeType: "image/png", data: Data(repeating: 7, count: 4096), name: "shot.png")],
                             delivery: .followUp)
            try await wait("refused saved") { ThreadRecovery.load(ref("refused"), defaults: defaults).map(\.state) == [.failed] }
            let saved = defaults.data(forKey: ThreadRecovery.key(ref("refused")))!
            check(saved.count < 512 && ThreadRecovery.load(ref("refused"), defaults: defaults)[0].images == 1,
                  "only the text and an image count are saved (\(saved.count) bytes)")
            run.cancel()
            let next = ThreadStores(defaults: defaults)
            let relaunched = next.store(for: ref("refused"))
            let id = next.recovered[ref("refused")]![0].id
            relaunched.draft = "a newer thought"
            check(next.restoreRecovered(id, for: ref("refused")) == nil && relaunched.draft == "a newer thought",
                  "a newer draft is never replaced")
            relaunched.draft = ""
            check(next.restoreRecovered(id, for: ref("refused"))?.typed == "ship the fix" && relaunched.draft == "ship the fix",
                  "restored as the draft of an empty composer")
            check(ThreadRecovery.load(ref("refused"), defaults: defaults).isEmpty && next.recovered[ref("refused")] == nil,
                  "and its saved copy goes")
        }

        // outcome_unknown, then a quit: unknown, never restorable.
        do {
            let threads = ThreadStores(defaults: defaults)
            let script = Script(refuse: "outcome_unknown")
            let store = threads.store(for: ref("unknown"))
            let run = Task { await store.run(request: script.request) }
            try await wait("ready") { store.ready }
            store.draft = "maybe sent"
            await store.send()
            try await wait("unknown saved") { ThreadRecovery.load(ref("unknown"), defaults: defaults).map(\.state) == [.uncertain] }
            run.cancel()
            let next = ThreadStores(defaults: defaults)
            _ = next.store(for: ref("unknown"))
            check(next.restoreRecovered(next.recovered[ref("unknown")]![0].id, for: ref("unknown")) == nil, "outcome_unknown is never restorable")
        }

        // Bounds: eight kept sends, or 16 MiB of text, refuse the next before anything is cleared.
        do {
            let threads = ThreadStores(defaults: defaults)
            let script = Script(refuse: "busy")
            let store = threads.store(for: ref("full"))
            let run = Task { await store.run(request: script.request) }
            try await wait("ready") { store.ready }
            for index in 1...ThreadRecovery.maximumRecords {
                store.draft = "refused \(index)"
                await store.send()
            }
            check(!threads.admits("ninth", for: ref("full")), "eight kept sends refuse a ninth")
            store.discardSubmission(store.submissions[0].id)
            check(threads.admits("ninth", for: ref("full")), "discarding one makes room")
            check(!threads.admits(String(repeating: "x", count: ThreadRecovery.maximumBytes), for: ref("full")),
                  "past the byte bound a send is refused")
            try await wait("seven saved") { ThreadRecovery.load(ref("full"), defaults: defaults).count == ThreadRecovery.maximumRecords - 1 }
            run.cancel()
            let next = ThreadStores(defaults: defaults)
            _ = next.store(for: ref("full"))
            check(next.recovered[ref("full")]?.count == ThreadRecovery.maximumRecords - 1 && next.admits(String(repeating: "x", count: 10), for: ref("full")),
                  "the next launch counts the earlier launch's kept sends (\(String(describing: next.recovered[ref("full")]?.count)))")
        }

        // Another version's or a damaged value; a forgotten host.
        do {
            let legacy = #"[{"id":"\#(UUID().uuidString)","typed":"older","state":"queued"}]"#
            defaults.set(Data(legacy.utf8), forKey: ThreadRecovery.key(ref("legacy")))
            let records = ThreadRecovery.load(ref("legacy"), defaults: defaults)
            check(records.map(\.typed) == ["older"] && records[0].state == .uncertain && records[0].images == 0,
                  "an older record decodes: unknown state is uncertain, no images")
            defaults.set(Data("not json".utf8), forKey: ThreadRecovery.key(ref("broken")))
            check(ThreadRecovery.load(ref("broken"), defaults: defaults).isEmpty && defaults.data(forKey: ThreadRecovery.key(ref("broken"))) == nil,
                  "a damaged value is dropped")
            let threads = ThreadStores(defaults: defaults)
            _ = threads.store(for: ref("legacy"))
            threads.forget(host: host)
            check(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(ThreadRecovery.prefix + host.uuidString) },
                  "forgetting the host removes every kept send of it")
        }
        print("PASS: unsent messages survive a quit as text only: held and outcome_unknown come back unknown (never restored or resent), refused restore only into an empty composer, new drafts kept apart, reconnect and acceptance, bounds refuse before clearing, older/damaged values, forget")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { fatalError("FAILED: \(what)") }
    }

    @MainActor
    static func wait(_ what: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("timed out: \(what)")
    }

    static func snapshot() -> NativeThreadSnapshot {
        let json: [String: Any] = [
            "piSessionID": "session", "generation": "generation", "revision": 1, "running": false,
            "supportedActions": ["send", "sendImages", "abort"], "dialogsSupported": false, "dialogs": [],
            "messages": [], "provisional": [], "clipped": false,
        ]
        return try! JSONDecoder().decode(NativeThreadSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

/// A host for one store: snapshots at once; a send held, or refused with `refuse`'s code.
@MainActor
final class Script {
    private(set) var requests: [NativeThreadRequest] = []
    private(set) var held: CheckedContinuation<NativeThreadResult, Error>?
    private(set) var heldOperation: UUID?
    let refuse: String?

    init(refuse: String? = nil) { self.refuse = refuse }

    var request: NativeThreadStore.Request {
        { [self] request in
            requests.append(request)
            switch request {
            case .snapshot(_, _, let revision):
                let current = MobileRecoveryCheck.snapshot()
                return revision == current.revision
                    ? .unchanged(piSessionID: current.piSessionID, generation: current.generation, revision: current.revision)
                    : .snapshot(value: current)
            case .send(_, _, let operation, _, _, _, _, _, _):
                if let refuse { return .failure(code: refuse, message: "Scripted \(refuse).") }
                heldOperation = operation
                return try await withCheckedThrowingContinuation { held = $0 }
            default:
                return .failure(code: "check", message: "Not scripted.")
            }
        }
    }

    func answer(_ result: NativeThreadResult) {
        held?.resume(returning: result)
        held = nil
    }
}

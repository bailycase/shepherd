import Darwin
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
            // At the moment the store's submissions change (observed as it changes, before the
            // append lands), the text is already saved.
            var savedAtCapture: [String]?
            let heldKey = ThreadRecovery.key(ref("held"))
            withObservationTracking { _ = store.submissions } onChange: {
                let data = defaults.data(forKey: heldKey) ?? Data()
                savedAtCapture = (try? JSONDecoder().decode([ThreadRecoveryRecord].self, from: data))?.map(\.typed)
            }
            let send = Task { await store.send() }
            try await wait("send held") { script.held != nil }
            check(savedAtCapture == ["hello there"], "the text is saved before the store captures it (\(String(describing: savedAtCapture)))")
            try await wait("saved while held, once") { ThreadRecovery.load(ref("held"), defaults: defaults).records.map(\.typed) == ["hello there"] }
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
            check(!ThreadRecovery.load(ref("held"), defaults: defaults).records.isEmpty, "a reconnect keeps the held send saved")
            script.answer(.accepted(operationID: script.heldOperation!))
            await send.value
            try await wait("accepted send is let go") { store.submissions.isEmpty }
            try await wait("and its saved copy") { ThreadRecovery.load(ref("held"), defaults: defaults).records.isEmpty }
            next.discardRecovered(next.recovered[ref("held")]![0].id, for: ref("held"))
            check(next.recovered[ref("held")] == nil && ThreadRecovery.load(ref("held"), defaults: defaults).records.isEmpty,
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
            try await wait("refused saved") { ThreadRecovery.load(ref("refused"), defaults: defaults).records.map(\.state) == [.failed] }
            let saved = defaults.data(forKey: ThreadRecovery.key(ref("refused")))!
            check(saved.count < 512 && ThreadRecovery.load(ref("refused"), defaults: defaults).records[0].images == 1,
                  "only the text and an image count are saved (\(saved.count) bytes)")
            run.cancel()
            let next = ThreadStores(defaults: defaults)
            let relaunched = next.store(for: ref("refused"))
            let id = next.recovered[ref("refused")]![0].id
            relaunched.draft = "a newer thought"
            check(next.restoreRecovered(id, for: ref("refused")) == nil && relaunched.draft == "a newer thought",
                  "a newer draft is never replaced")
            relaunched.draft = ""
            check(next.restoreRecovered(id, for: ref("refused"))?.typed == "ship the fix" && relaunched.draft == "ship the fix"
                  && defaults.string(forKey: NativeDraftKey.text(host: host, agent: AgentID(rawValue: "refused"))) == "ship the fix",
                  "restored as the draft of an empty composer, saved as the draft before its copy goes")
            check(ThreadRecovery.load(ref("refused"), defaults: defaults).records.isEmpty && next.recovered[ref("refused")] == nil,
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
            try await wait("unknown saved") { ThreadRecovery.load(ref("unknown"), defaults: defaults).records.map(\.state) == [.uncertain] }
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
            func sends() -> Int { script.requests.filter { if case .send = $0 { true } else { false } }.count }
            var sent = sends()
            store.draft = "ninth"
            check(await store.send(delivery: .followUp) == false && store.draft == "ninth" && store.submissions.count == ThreadRecovery.maximumRecords
                  && sends() == sent, "eight kept sends refuse a ninth before anything is cleared or sent")
            store.discardSubmission(store.submissions[0].id)
            await store.send()
            check(sends() == sent + 1 && store.draft.isEmpty, "discarding one makes room")
            store.discardSubmission(store.submissions[0].id)
            sent = sends()
            try await wait("seven saved") { ThreadRecovery.load(ref("full"), defaults: defaults).records.count == ThreadRecovery.maximumRecords - 1 }
            run.cancel()
            let next = ThreadStores(defaults: defaults)
            _ = next.store(for: ref("full"))
            check(next.recovered[ref("full")]?.count == ThreadRecovery.maximumRecords - 1,
                  "the next launch counts the earlier launch's kept sends (\(String(describing: next.recovered[ref("full")]?.count)))")
        }

        // A send waiting for the thread to be ready, its draft grown meanwhile past what may be
        // kept with an earlier launch's 16 MiB: refused at capture, the draft as it now is.
        do {
            let near = String(repeating: "z", count: ThreadRecovery.maximumBytes - 16)
            ThreadRecovery.save([ThreadRecoveryRecord(id: UUID(), typed: near, state: .failed, images: 0)], for: ref("ready"), defaults: defaults)
            let threads = ThreadStores(defaults: defaults)
            let script = Script(holdSnapshot: true)
            let store = threads.store(for: ref("ready"))
            let run = Task { await store.run(request: script.request) }
            try await wait("readiness held") { script.heldSnapshot != nil }
            store.draft = "short"
            let send = Task { await store.send(delivery: .followUp) }
            try await Task.sleep(for: .milliseconds(50))
            store.draft = "grown while waiting past the bound"
            script.releaseSnapshot()
            let sent = await send.value
            check(!sent && store.draft == "grown while waiting past the bound" && store.submissions.isEmpty
                  && !script.requests.contains { if case .send = $0 { true } else { false } },
                  "refused on the payload actually captured; the draft kept, nothing sent")
            check(ThreadRecovery.load(ref("ready"), defaults: defaults).records.map(\.typed) == [near], "the kept record unchanged")
            run.cancel()
        }

        // Saved lists checked before they show: bad entries skipped, a repeated id renewed, and a
        // list past the bounds set aside whole before only what fits shows.
        do {
            let same = UUID().uuidString
            let small = "[" + #"{"id":"\#(same)","typed":"keep me","state":"failed","images":-3}"#
                + #",{"typed":"no id"},42,{"id":"\#(same)","typed":"same id, other text","state":"failed"}]"#
            defaults.set(Data(small.utf8), forKey: ThreadRecovery.key(ref("mixed")))
            let loaded = ThreadRecovery.load(ref("mixed"), defaults: defaults)
            check(loaded.records.map(\.typed) == ["keep me", "no id", "same id, other text"] && loaded.setAside
                  && Set(loaded.records.map(\.id)).count == 3 && loaded.records[0].images == 0,
                  "readable entries show; a record without an id or with a repeated one gets its own; a negative image count is none")
            check(ThreadRecovery.asideKeys(ref("mixed"), defaults: defaults).compactMap { defaults.data(forKey: $0) } == [Data(small.utf8)],
                  "a list with an unreadable entry is set aside whole before anything saves over it")
            let threads = ThreadStores(defaults: defaults)
            let mixed = threads.store(for: ref("mixed"))
            let records = threads.recovered[ref("mixed")]!
            check(threads.restoreRecovered(records[0].id, for: ref("mixed"))?.typed == "keep me"
                  && threads.recovered[ref("mixed")]?.map(\.typed) == ["no id", "same id, other text"],
                  "restoring one of two once-identical ids takes only that one")
            mixed.draft = ""

            let over = "[" + (1...10).map { #"{"id":"\#(UUID().uuidString)","typed":"extra \#($0)","state":"failed"}"# }.joined(separator: ",") + "]"
            defaults.set(Data(over.utf8), forKey: ThreadRecovery.key(ref("over")))
            let next = ThreadStores(defaults: defaults)
            let overStore = next.store(for: ref("over"))
            let overScript = Script(refuse: "busy")
            let overRun = Task { await overStore.run(request: overScript.request) }
            try await wait("over ready") { overStore.ready }
            overStore.draft = "more"
            let overSent = await overStore.send(delivery: .followUp)
            overRun.cancel()
            let aside = ThreadRecovery.asideKeys(ref("over"), defaults: defaults)
            check(aside.count == 1 && defaults.data(forKey: aside[0]) == Data(over.utf8), "a list past the count bound is set aside whole, untouched")
            check(next.recovered[ref("over")]?.map(\.typed) == (1...ThreadRecovery.maximumRecords).map { "extra \($0)" }
                  && next.setAside.contains(ref("over")) && !overSent && overStore.draft == "more" && overStore.submissions.isEmpty,
                  "then only what fits shows, said so, and new sends wait")
            let huge = String(repeating: "y", count: ThreadRecovery.maximumBytes / 2 + 1)
            let heavy = "[" + (1...3).map { _ in #"{"id":"\#(UUID().uuidString)","typed":"\#(huge)","state":"failed"}"# }.joined(separator: ",") + "]"
            defaults.set(Data(heavy.utf8), forKey: ThreadRecovery.key(ref("heavy")))
            let weighed = ThreadRecovery.load(ref("heavy"), defaults: defaults)
            check(weighed.setAside && weighed.records.count == 1 && ThreadRecovery.asideKeys(ref("heavy"), defaults: defaults).count == 1,
                  "a list past the byte bound is set aside whole; what fits shows")
            defaults.set(Data("{\"not\": \"a list\"}".utf8), forKey: ThreadRecovery.key(ref("odd")))
            check(ThreadRecovery.load(ref("odd"), defaults: defaults).records.isEmpty
                  && ThreadRecovery.asideKeys(ref("odd"), defaults: defaults).compactMap { defaults.data(forKey: $0) } == [Data("{\"not\": \"a list\"}".utf8)],
                  "a value that is not a list is set aside untouched, not deleted")
        }

        // A connected host deletes a thread still on screen while a send is held: its kept sends
        // go; the late refusal writes nothing back, nor does anything after the host drops and
        // returns; a deletion while away is caught on its return.
        do {
            let server = try PruneHost(agents: ["gone", "stays", "later"])
            let hosts = MobileHosts(defaults: defaults, tokens: .memory(), pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
            let hostID = try hosts.add(RemoteHostEntry(name: "Prune", address: "127.0.0.1", port: String(server.port), token: PruneHost.token))
            let threads = ThreadStores(defaults: defaults)
            threads.track(hosts)
            hosts.setForeground(true)
            try await wait("prune host connected") { hosts.host(hostID)?.phase == .connected && hosts.host(hostID)?.state.agents.count == 3 }
            let gone = AgentRef(host: hostID, agent: AgentID(rawValue: "gone"))
            let stays = AgentRef(host: hostID, agent: AgentID(rawValue: "stays"))
            let later = AgentRef(host: hostID, agent: AgentID(rawValue: "later"))
            let script = Script()
            let store = threads.store(for: gone)
            let run = Task { await store.run(request: script.request) }
            try await wait("ready") { store.ready && store.isLive }
            store.draft = "held when deleted"
            let send = Task { await store.send() }
            try await wait("held") { script.held != nil }
            try await wait("saved") { !ThreadRecovery.load(gone, defaults: defaults).records.isEmpty }
            ThreadRecovery.save([ThreadRecoveryRecord(id: UUID(), typed: "other thread", state: .failed, images: 0)], for: stays, defaults: defaults)
            server.push(["stays", "later"])
            try await wait("deleted thread's records pruned") { defaults.data(forKey: ThreadRecovery.key(gone)) == nil }
            script.answer(.failure(code: "busy", message: "late"))
            await send.value
            try await wait("late refusal settles") { store.submissions.first?.state == .failed }
            try await Task.sleep(for: .milliseconds(200))
            check(defaults.data(forKey: ThreadRecovery.key(gone)) == nil, "the late refusal of the deleted, visible thread writes nothing back")
            // The host drops; while away `later` is deleted there and its records are written.
            // A new send from the deleted thread still on screen: refused, its draft kept.
            store.draft = "after deletion"
            let refusedSends = script.requests.filter { if case .send = $0 { true } else { false } }.count
            check(await store.send(delivery: .followUp) == false && store.draft == "after deletion"
                  && script.requests.filter { if case .send = $0 { true } else { false } }.count == refusedSends
                  && (store.notice ?? "").contains("no longer on its host"),
                  "a deleted thread refuses a new send and keeps the draft")
            hosts.disconnect(hostID)
            try await wait("prune host away") { hosts.host(hostID)?.phase == .disconnected }
            store.draft = "while away"
            store.discardSubmission(store.submissions[0].id)
            ThreadRecovery.save([ThreadRecoveryRecord(id: UUID(), typed: "deleted while away", state: .failed, images: 0)], for: later, defaults: defaults)
            server.push(["stays"])
            hosts.retry(hostID)
            try await wait("prune host back") { hosts.host(hostID)?.phase == .connected && hosts.host(hostID)?.state.agents.count == 1 }
            try await wait("a deletion while away is caught on return") { defaults.data(forKey: ThreadRecovery.key(later)) == nil }
            check(defaults.data(forKey: ThreadRecovery.key(gone)) == nil, "the deleted thread stays fenced across the reconnect")
            check(ThreadRecovery.load(stays, defaults: defaults).records.map(\.typed) == ["other thread"], "another thread's records stay")
            run.cancel()
            hosts.setForeground(false)
        }

        // Another version's or a damaged value; a forgotten host.
        do {
            let legacy = #"[{"id":"\#(UUID().uuidString)","typed":"older","state":"queued"}]"#
            defaults.set(Data(legacy.utf8), forKey: ThreadRecovery.key(ref("legacy")))
            let records = ThreadRecovery.load(ref("legacy"), defaults: defaults).records
            check(records.map(\.typed) == ["older"] && records[0].state == .uncertain && records[0].images == 0,
                  "an older record decodes: unknown state is uncertain, no images")
            defaults.set(Data("not json".utf8), forKey: ThreadRecovery.key(ref("broken")))
            check(ThreadRecovery.load(ref("broken"), defaults: defaults).records.isEmpty && defaults.data(forKey: ThreadRecovery.key(ref("broken"))) == nil
                  && ThreadRecovery.asideKeys(ref("broken"), defaults: defaults).count == 1,
                  "a damaged value is set aside, not thrown away")
            let threads = ThreadStores(defaults: defaults)
            _ = threads.store(for: ref("legacy"))
            threads.forget(host: host)
            check(!defaults.dictionaryRepresentation().keys.contains {
                $0.hasPrefix(ThreadRecovery.prefix + host.uuidString) || $0.hasPrefix(ThreadRecovery.asidePrefix + host.uuidString)
            },
                  "forgetting the host removes every kept send of it")
        }
        print("PASS: unsent messages survive an orderly relaunch (UserDefaults; no fsync-grade crash assurance) as text only: saved at capture admission before the composer clears, payload-checked after readiness: held and outcome_unknown come back unknown (never restored or resent), refused restore only into an empty composer, new drafts kept apart, reconnect and acceptance, bounds refuse before clearing, older/damaged values, forget")
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
    private(set) var heldSnapshot: CheckedContinuation<NativeThreadResult, Error>?
    let refuse: String?
    private var holdSnapshot: Bool

    init(refuse: String? = nil, holdSnapshot: Bool = false) {
        self.refuse = refuse
        self.holdSnapshot = holdSnapshot
    }

    func releaseSnapshot() {
        heldSnapshot?.resume(returning: .snapshot(value: MobileRecoveryCheck.snapshot()))
        heldSnapshot = nil
    }

    var request: NativeThreadStore.Request {
        { [self] request in
            requests.append(request)
            switch request {
            case .snapshot(_, _, let revision):
                if holdSnapshot {
                    holdSnapshot = false
                    return try await withCheckedThrowingContinuation { heldSnapshot = $0 }
                }
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

/// A host that answers hello and its state with the named agents, and pushes a new list on demand.
final class PruneHost: @unchecked Sendable {
    static let token = "prune-token"
    let port: UInt16
    private let lock = NSLock()
    private var agents: [String]
    private var clients: [Int32] = []

    init(agents: [String]) throws {
        self.agents = agents
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(fd >= 0 && bound == 0 && listen(fd, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var one: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    private func state() -> ShepherdState {
        let space = Space(id: SpaceID(rawValue: "home"), name: "Home", path: "/src")
        return ShepherdState(spaces: [space], agents: lock.withLock { agents }.map {
            Agent(id: AgentID(rawValue: $0), name: $0, spaceID: space.id, tabID: TabID(rawValue: "t-" + $0), status: .idle)
        })
    }

    func push(_ next: [String]) {
        let live = lock.withLock { agents = next; return clients }
        for client in live { try? write(client, .stateChanged(state: state())) }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        do {
            guard case .hello(let id, let token, _, _, _) = try NDJSON.decode(RemoteRequest.self, from: readLine(client)), token == Self.token else { return }
            try write(client, .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.nativeThreadCapability]))
            while true {
                if case .stateFetch(let id) = try NDJSON.decode(RemoteRequest.self, from: readLine(client)) {
                    lock.withLock { clients.append(client) }
                    try write(client, .state(id: id, state: state()))
                }
            }
        } catch {
            return
        }
    }

    private func readLine(_ fd: Int32) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == 10 { return line }
            line.append(byte)
        }
        throw CocoaError(.fileReadUnknown)
    }

    private let writing = NSLock()
    private func write(_ fd: Int32, _ reply: RemoteReply) throws {
        let data = try NDJSON.encode(reply)
        let written = writing.withLock { data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) } }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
}

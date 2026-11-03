import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote
@testable import ShepherdApp

/// A send's words leave the composer when the store captures them. Until the host accepts them
/// they are kept in defaults too, so a quit or crash never loses them: after a relaunch they are
/// back as of unknown outcome (never sent again), beside any draft typed since.
@Suite("Composer recovery across relaunch", .timeLimit(.minutes(1)))
@MainActor
struct ComposerRecoveryRelaunchTests {
    typealias Host = ComposerSubmissionTests.Host
    let defaults = Fixture.defaults()
    let id = AgentID()

    private func launch() -> NativeThreadStores<AgentID> {
        let stores = NativeThreadStores<AgentID>()
        stores.drafts = ComposerDrafts(defaults: defaults)
        return stores
    }

    private func run(_ store: NativeThreadStore, _ host: Host) async -> Task<Void, Never> {
        let loop = Task { await store.run(request: { try await host.request($0) }) }
        while !store.ready {
            await withCheckedContinuation { changed in withObservationTracking { _ = store.ready } onChange: { changed.resume() } }
        }
        return loop
    }

    /// What a crash right now would leave in defaults.
    private func persisted() -> [NativeRecoveredSubmission] { ComposerDrafts(defaults: defaults).recovered(id.rawValue) }

    @Test func aSendStillWaitingAtTheQuitComesBackAsUnknownAndIsNeverResent() async {
        let host = Host()
        host.holding = true
        let stores = launch()
        let store = stores.store(for: id)
        let loop = await run(store, host)
        defer { loop.cancel(); host.hold?.resume() }
        store.draft = "Words typed before the crash"
        stores.drafts?.flush()
        var send: Task<Bool, Never>?
        await withCheckedContinuation { held in
            host.whenSendHeld = { held.resume() }
            send = Task { await store.send(delivery: .followUp) }
        }
        _ = send
        // Captured: the words are kept as a record, and no longer as the draft.
        #expect(store.draft.isEmpty)
        #expect(persisted().map(\.typed) == ["Words typed before the crash"])
        #expect(ComposerDrafts(defaults: defaults).restore(id.rawValue) == nil)

        // The app dies here. Relaunched:
        let relaunched = launch().store(for: id)
        #expect(relaunched.submissions.map(\.typed) == ["Words typed before the crash"])
        #expect(relaunched.submissions.map(\.state) == [.uncertain])
        #expect(relaunched.restoreSubmission(relaunched.submissions[0].id) == nil, "never restored as refused")
        #expect(relaunched.draft.isEmpty)
    }

    @Test func refusedAndUnknownSendsAndANewDraftAllComeBack() async {
        let host = Host()
        let stores = launch()
        let store = stores.store(for: id)
        let loop = await run(store, host)
        defer { loop.cancel() }
        host.answer = .refuse
        store.draft = "Refused one"
        await store.send(delivery: .followUp)
        host.answer = .unknown
        store.draft = "Unknown one"
        await store.send(delivery: .followUp)
        #expect(store.submissions.map(\.state) == [.failed, .uncertain])
        store.draft = "Typed since"
        stores.drafts?.note(id.rawValue, draft: store.draft)
        stores.drafts?.flush()
        #expect(persisted().map(\.typed) == ["Refused one", "Unknown one"])

        let relaunched = launch().store(for: id)
        #expect(relaunched.draft == "Typed since", "the new draft is kept apart from the records")
        #expect(relaunched.submissions.map(\.typed) == ["Refused one", "Unknown one"])
        #expect(relaunched.submissions.allSatisfy { $0.state == .uncertain }, "a relaunch cannot vouch that a refusal was final")
        #expect(host.sends == 2, "nothing resent")
    }

    @Test func acceptedDiscardedAndRestoredRecordsLeaveDefaults() async {
        let host = Host()
        let stores = launch()
        let store = stores.store(for: id)
        let loop = await run(store, host)
        defer { loop.cancel() }
        host.answer = .accept
        store.draft = "Accepted"
        #expect(await store.send(delivery: .followUp))
        host.answer = .unknown
        store.draft = "To discard"
        await store.send(delivery: .followUp)
        host.answer = .refuse
        store.draft = "To restore"
        await store.send(delivery: .followUp)
        #expect(persisted().map(\.typed) == ["To discard", "To restore"], "an accepted send is not kept")

        #expect(store.discardSubmission(store.submissions[0].id))
        #expect(store.restoreSubmission(store.submissions[0].id) != nil)
        // Written with the draft as it then is: the restored words are never only in memory.
        while !persisted().isEmpty { await Task.yield() }
        #expect(ComposerDrafts(defaults: defaults).restore(id.rawValue) == "To restore")
        #expect(launch().store(for: id).submissions.isEmpty)
    }

    @Test func aLegacyDraftAloneStillComesBack() {
        defaults.set([id.rawValue: "From an older Shepherd"], forKey: ComposerDrafts.key)
        let store = launch().store(for: id)
        #expect(store.draft == "From an older Shepherd")
        #expect(store.submissions.isEmpty)
    }

    /// Every single defaults write, through a held send's capture and a refused send's restore, leaves
    /// the words somewhere a relaunch reads: the saved draft or a recovery record. (Write order only:
    /// the system persists defaults on its own schedule, so this is not a crash-at-any-instant guarantee.)
    @Test func noWriteLeavesTheWordsInNeitherTheDraftNorARecord() async {
        let host = Host()
        let stores = launch()
        let drafts = stores.drafts!
        let words = "Never only in memory"
        var violations: [String] = []
        let check = { [defaults, id] (stage: String) in
            let draft = (defaults.dictionary(forKey: ComposerDrafts.key) as? [String: String])?[id.rawValue]
            let records = defaults.data(forKey: ComposerDrafts.recoveriesKey)
                .flatMap { try? JSONDecoder().decode([String: [NativeRecoveredSubmission]].self, from: $0) }?[id.rawValue] ?? []
            if draft != words && !records.contains(where: { $0.typed == words }) { violations.append(stage) }
        }
        let store = stores.store(for: id)
        let loop = await run(store, host)
        defer { loop.cancel(); host.hold?.resume() }
        store.draft = words
        drafts.note(id.rawValue, draft: words)
        drafts.flush()
        drafts.onWrite = { check("capture") }
        host.holding = true
        host.answer = .refuse
        var send: Task<Bool, Never>?
        await withCheckedContinuation { held in
            host.whenSendHeld = { held.resume() }
            send = Task { await store.send(delivery: .followUp) }
        }
        #expect(store.draft.isEmpty)
        // The emptied draft's own (debounced) save, had it run now.
        drafts.note(id.rawValue, draft: store.draft)
        drafts.flush()
        host.holding = false
        host.hold?.resume()
        host.hold = nil
        _ = await send?.value
        drafts.onWrite = { check("restore") }
        #expect(store.restoreSubmission(store.submissions[0].id) != nil)
        while !persisted().isEmpty { await Task.yield() }
        #expect(violations.isEmpty, "\(violations)")
        #expect(ComposerDrafts(defaults: defaults).restore(id.rawValue) == words)
    }
}

extension ComposerRecoveryRelaunchTests {
    /// Saved records past the bounds (repeated ids, too many) are taken in only within them, and the
    /// saved value is kept whole beside them rather than truncated away; unreadable data likewise.
    @Test func savedRecordsPastTheBoundsAreQuarantinedNotTruncated() throws {
        let repeated = UUID()
        let records = [NativeRecoveredSubmission(id: repeated, typed: "first", sessionID: nil, generation: nil, capturedAt: 1),
                       NativeRecoveredSubmission(id: repeated, typed: "second, same id", sessionID: nil, generation: nil, capturedAt: 2)]
            + (0..<10).map { NativeRecoveredSubmission(id: UUID(), typed: "more \($0)", sessionID: nil, generation: nil, capturedAt: 3) }
        let data = try JSONEncoder().encode([id.rawValue: records])
        defaults.set(data, forKey: ComposerDrafts.recoveriesKey)
        let drafts = ComposerDrafts(defaults: defaults)
        let loaded = drafts.recovered(id.rawValue)
        #expect(loaded.count == NativeThreadStore.maximumRetainedSubmissions)
        #expect(Set(loaded.map(\.id)).count == loaded.count)
        #expect(loaded.first?.typed == "first")
        #expect(defaults.array(forKey: ComposerDrafts.quarantineKey) as? [Data] == [data], "the saved value is kept whole")

        let other = Fixture.defaults()
        other.set(Data("not json".utf8), forKey: ComposerDrafts.recoveriesKey)
        #expect(ComposerDrafts(defaults: other).recovered(id.rawValue).isEmpty)
        #expect(other.array(forKey: ComposerDrafts.quarantineKey) as? [Data] == [Data("not json".utf8)])

        // One unreadable record among good ones: the good ones come back, and the whole value is kept.
        let mixed = Fixture.defaults()
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records[0])) as! [String: Any]
        let damaged: [Any] = [good, ["id": "not a uuid"], "not an object", 7, true, NSNull()]
        let raw = try JSONSerialization.data(withJSONObject: [id.rawValue: damaged, "bad-agent": "not an array"])
        mixed.set(raw, forKey: ComposerDrafts.recoveriesKey)
        let recovered = ComposerDrafts(defaults: mixed)
        #expect(recovered.recovered(id.rawValue).map(\.typed) == ["first"])
        #expect(recovered.recovered("bad-agent").isEmpty)
        #expect(mixed.array(forKey: ComposerDrafts.quarantineKey) as? [Data] == [raw])
        recovered.flush()
        let relaunched = ComposerDrafts(defaults: mixed)
        #expect(relaunched.recovered(id.rawValue).map(\.typed) == ["first"])
        #expect(mixed.array(forKey: ComposerDrafts.quarantineKey) as? [Data] == [raw], "rewrite preserves quarantined originals")
    }

    /// A deleted agent's store, captured and then pruned, writes nothing after it is gone.
    @Test func aPrunedAgentsStoreWritesNothingLate() async {
        let host = Host()
        let stores = launch()
        let store = stores.store(for: id)
        let loop = await run(store, host)
        defer { loop.cancel() }
        host.answer = .refuse
        store.draft = "about to be deleted"
        await store.send(delivery: .followUp)
        #expect(persisted().count == 1)
        stores.prune(live: [])
        _ = store.discardSubmission(store.submissions[0].id)
        await Task.yield()
        #expect(persisted().count == 1, "no write for an agent that is gone")
    }
}

extension ComposerRecoveryRelaunchTests {
    /// Records from before the relaunch and live ones share one budget, checked on the exact capture: a send
    /// past it captures nothing, and the draft and the composer's images stay as they were.
    @Test func theBudgetCoversRecoveredAndLiveRecordsAtTheCapture() async throws {
        let earlier = (0..<(NativeThreadStore.maximumRetainedSubmissions - 1)).map {
            NativeRecoveredSubmission(id: UUID(), typed: "earlier \($0)", sessionID: "s", generation: "g", capturedAt: 1)
        }
        defaults.set(try JSONEncoder().encode([id.rawValue: earlier]), forKey: ComposerDrafts.recoveriesKey)
        let host = Host()
        host.answer = .unknown
        let stores = launch()
        let store = stores.store(for: id)
        #expect(store.submissions.count == earlier.count)
        let loop = await run(store, host)
        defer { loop.cancel() }
        let input = ThreadInput()
        store.draft = "fills the budget"
        await ComposerImageCapture.send(store: store, input: input, delivery: .followUp)
        #expect(persisted().count == NativeThreadStore.maximumRetainedSubmissions)

        input.attachments.add([("kept.png", ImageAttachment(name: "kept.png", image: NativeImage(mimeType: "image/png", data: Data([1]))))])
        store.draft = "one too many"
        let sends = host.sends
        #expect(await ComposerImageCapture.send(store: store, input: input, delivery: .followUp) == false)
        #expect(host.sends == sends)
        #expect(store.draft == "one too many")
        #expect(input.attachments.items.map(\.name) == ["kept.png"])
        #expect(persisted().count == NativeThreadStore.maximumRetainedSubmissions, "nothing written for a refused capture")

        // Recovered records are read-only: no restore, no retry; only discard (which frees room).
        let recovered = try #require(store.submissions.first)
        #expect(recovered.state == .uncertain)
        #expect(!ThreadSubmissions.canRestore(recovered, store: store, input: input))
        #expect(store.restoreSubmission(recovered.id) == nil)
        #expect(store.discardSubmission(recovered.id))
        while persisted().count == NativeThreadStore.maximumRetainedSubmissions { await Task.yield() }
        #expect(!persisted().contains { $0.id == recovered.id }, "a discarded record is not written back")
    }

    /// A refused send restored and then edited: the relaunch brings back the edited draft, not the record.
    @Test func aRestoredThenEditedDraftIsWhatComesBack() async {
        let host = Host()
        let stores = launch()
        let store = stores.store(for: id)
        let loop = await run(store, host)
        defer { loop.cancel() }
        store.draft = "first wording"
        await store.send(delivery: .followUp)
        #expect(store.restoreSubmission(store.submissions[0].id) != nil)
        while !persisted().isEmpty { await Task.yield() }
        store.draft = "second wording"
        stores.drafts?.note(id.rawValue, draft: store.draft)
        stores.drafts?.flush()
        let relaunched = launch().store(for: id)
        #expect(relaunched.draft == "second wording")
        #expect(relaunched.submissions.isEmpty)
    }
}

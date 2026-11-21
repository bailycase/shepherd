import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A thread far from the screen lets its older history go and keeps its tail (`NativeThreadStore.releaseToTail`): what it draws
/// first when it is shown again, with no pull, no parse and no row built again when the pull lands.
@Suite("Thread released to its tail", .timeLimit(.minutes(1)))
@MainActor
struct ThreadReleasedTailTests {
    typealias F = Fixture

    /// `turns` questions and their answers, the answers of `text` (two paragraphs of prose each).
    private func session(turns: Int, text: String = "Answer.\n\nMore of the answer, in a second paragraph.") -> [NativeThreadMessage] {
        (0..<turns).flatMap { [F.user("Question \($0)", id: "u\($0)"), F.assistant("\(text) \($0)", id: "a\($0)")] }
    }

    /// A store that holds `messages` and is not on screen: nothing polls it.
    private func hidden(_ messages: [NativeThreadMessage], running: Bool = false) async -> (NativeThreadStore, FakeHost) {
        let host = FakeHost(F.snapshot(running: running, messages: messages))
        let store = manualStore()
        let task = await start(store, host)
        task.cancel()
        store.suspend()
        return (store, host)
    }

    @Test func releasingToTheTailKeepsTheEndOfTheThreadWithItsRowsAndLetsOlderHistoryGo() async {
        let all = session(turns: 100)
        let (store, _) = await hidden(all)
        let rows = store.rows, bytes = store.retainedHistoryBytes
        #expect(rows.count == 200 && store.messages.count == 200)
        store.draft = "keep me"

        store.releaseToTail(rows: 30, maxBytes: .max)
        #expect(store.keepsOnlyTail && store.holdsHistory)
        #expect(store.messages == Array(all.suffix(NativeThreadStore.releasedTailMessages)), "at least what the host's newest page holds")
        #expect(store.rows == Array(rows.suffix(store.messages.count)), "the rows it had, with the same identities and presentations")
        #expect(store.olderCursor == store.messages.first?.entryID, "older history pages in from where the tail starts")
        #expect(store.snapshot?.olderCursor == store.olderCursor)
        #expect(store.snapshot?.messages.allSatisfy { store.messages.contains($0) } == true)
        #expect(store.retainedHistoryBytes < bytes / 2, "most of what it held went: \(store.retainedHistoryBytes) of \(bytes)")
        #expect(store.draft == "keep me")
    }

    @Test func theTailStartsAtAQuestionAndItsRowsAreWhatTheFullThreadDraws() async {
        // Tool calls make a reply of several messages: the tail begins at a question, never in the middle of a reply.
        var all: [NativeThreadMessage] = []
        for turn in 0..<40 {
            all.append(F.user("Question \(turn)", id: "u\(turn)"))
            all += (0..<4).map { F.tool("bash", args: "{\"command\":\"echo \($0)\"}", output: "out", id: "t\(turn)-\($0)", callID: "c\(turn)-\($0)") }
            all.append(F.assistant("Done \(turn).", id: "a\(turn)"))
        }
        let (store, _) = await hidden(all)
        let rows = store.rows
        #expect(rows.count == 80)

        store.releaseToTail(rows: 6, maxBytes: .max)
        #expect(store.messages.first?.role == "user", "it keeps whole turns: \(store.messages.first?.entryID ?? "")")
        #expect(store.messages.count >= NativeThreadStore.releasedTailMessages && store.rows.count >= 6)
        #expect(store.rows == Array(rows.suffix(store.rows.count)))
    }

    @Test func aTailOverItsCapShrinksToTheLastTurnsAndKeepsTheLastOne() async {
        let (store, _) = await hidden(session(turns: 100, text: String(repeating: "word ", count: 400)))
        let whole = store.retainedHistoryBytes
        store.releaseToTail(rows: 30, maxBytes: whole / 40)
        #expect(store.retainedHistoryBytes <= whole / 40, "\(store.retainedHistoryBytes) of \(whole / 40)")
        #expect(store.rows.count >= 2 && store.rows.last?.id == "u99/reply", "the end of the thread is always there")
        #expect(store.messages.first?.role == "user")

        let (small, _) = await hidden(session(turns: 100, text: String(repeating: "word ", count: 400)))
        small.releaseToTail(rows: 30, maxBytes: 1)
        #expect(small.messages.map(\.entryID) == ["u99", "a99"], "under any cap, the last question and its answer")
    }

    @Test func aThreadThatWasRunningIsNotLiveWhileItWaitsForItsPull() async {
        let (store, _) = await hidden(session(turns: 3), running: true)
        #expect(store.running && store.liveRowID != nil)
        store.releaseToTail(rows: 30, maxBytes: .max)
        #expect(!store.running && store.liveRowID == nil && store.rows.allSatisfy { !$0.live }, "what it was doing when it left is not what it is doing now")
    }

    /// The tail's release shows the thread as not running until its pull lands. On a warm reconnect (the same connection, as the phone
    /// and iPad have it) a host that is still mid-turn with nothing new to say answers "unchanged": the view has to take its run state
    /// from the host's last word then, not keep the release's.
    @Test func aThreadReleasedMidTurnRunsAgainWhenTheHostSaysUnchanged() async {
        let host = FakeHost(F.snapshot(running: true, messages: session(turns: 3)))
        host.answersUnchanged = true
        let store = manualStore()
        let first = await start(store, host, connection: "link")
        first.cancel()
        store.suspend()
        store.releaseToTail(rows: 30, maxBytes: .max)
        #expect(!store.running)

        let again = await start(store, host, connection: "link")
        defer { again.cancel() }
        #expect(host.requests.last.map { if case .snapshot(_, _, let after) = $0 { after != nil } else { false } } == true, "a warm pull names its revision")
        #expect(store.running && store.hostRunning, "the host never stopped: the thread says so")
    }

    /// A turn ends and Stop stays for the 400 ms hold. A pull that lands inside it and finds nothing new (the host says "unchanged")
    /// is not a new word from the host: it must not start the hold over.
    @Test func anUnchangedPullKeepsTheEndOfRunHoldInFlight() async throws {
        let prompt = F.user("go", id: "u")
        let host = FakeHost(F.snapshot(running: true, messages: [prompt]))
        host.answersUnchanged = true
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        let (hold, release) = AsyncStream<Void>.makeStream()
        store.settlePause = { _ in for await _ in hold {} }
        defer { release.finish() }
        host.snapshot = F.snapshot(revision: 2, messages: [prompt, F.assistant("Done.", id: "a")])
        await store.refresh()
        let settling = try #require(store.settleTask)
        #expect(store.settledRunning, "Stop stays through the hold")

        await store.refresh()
        #expect(host.requests.last.map { if case .snapshot(_, _, let after) = $0 { after == 2 } else { false } } == true)
        #expect(store.settleTask == settling && !settling.isCancelled, "the pending hold is the one that ends the turn")
        release.finish()
        await settling.value
        #expect(!store.settledRunning)
    }

    /// The rows the host adds while a turn runs (its question and the reply so far) are not history: the tail starts in history, and they stay.
    @Test func theLiveRowsOfAThreadThatLeftRunningStayAfterTheTail() async {
        let all = session(turns: 100)
        let live = [F.user("Go on", id: "provisional:u"), F.assistant("Working on it", status: "streaming", id: "provisional:a")]
        let host = FakeHost(F.snapshot(running: true, messages: all, provisional: live))
        let store = manualStore()
        let task = await start(store, host)
        task.cancel()
        store.suspend()
        let rows = store.rows
        #expect(rows.count == 202)

        store.releaseToTail(rows: 2, maxBytes: .max)
        #expect(store.messages.first?.role == "user" && store.messages.count >= NativeThreadStore.releasedTailMessages)
        #expect(store.rows.suffix(2).map(\.id) == rows.suffix(2).map(\.id), "the live rows keep their identities")
        #expect(store.rows.count == store.messages.count + 2 && !store.running)
    }

    /// A thread that holds no question (a page that starts inside one long reply, or a thread an automation opened) holds one agent turn
    /// (`nativeTurns` merges what is not a question), the last answer, which the rule keeps whatever it holds, as it keeps a question's.
    @Test func aThreadWithNoQuestionIsLeftAsItIs() async {
        let (store, _) = await hidden((0..<20).map { F.assistant("Note \($0)", id: "a\($0)") })
        let rows = store.rows
        store.releaseToTail(rows: 2, maxBytes: 1)
        #expect(store.keepsOnlyTail && store.rows == rows && store.messages.count == 20, "nothing to cut at")

        let (page, _) = await hidden((0..<NativeThreadStore.releasedTailMessages).map { F.assistant(String(repeating: "word ", count: 400) + "\($0)", id: "a\($0)") })
        page.releaseToTail(rows: 2, maxBytes: 1)
        #expect(page.keepsOnlyTail && page.holdsHistory && page.messages.count == NativeThreadStore.releasedTailMessages, "one page is never cut or released")
    }

    /// Only what older pages added above the host's newest page (the first pull lands over it) is cut from a thread with no question, and
    /// only when it is over the cap.
    @Test func aThreadWithNoQuestionThatPagedOlderHistoryInKeepsItsNewestPageOverTheCap() async {
        let notes = (0..<120).map { F.assistant(String(repeating: "word ", count: 400) + "\($0)", id: "a\($0)") }
        let (store, _) = await hidden(notes)
        let whole = store.retainedHistoryBytes
        store.releaseToTail(rows: 2, maxBytes: whole / 2)
        #expect(store.keepsOnlyTail && store.messages == Array(notes.suffix(NativeThreadStore.releasedTailMessages)), "the host's newest page")
        #expect(store.olderCursor == "a70" && store.snapshot?.olderCursor == "a70", "older history pages in from where it starts")
        #expect(store.retainedHistoryBytes <= whole / 2, "\(store.retainedHistoryBytes) of \(whole / 2)")

        let (within, _) = await hidden(notes)
        within.releaseToTail(rows: 2, maxBytes: .max)
        #expect(within.keepsOnlyTail && within.messages == notes, "within the cap it holds all it held")
    }

    /// The last question and its answer stay whatever they hold, even when the thread is nothing but them.
    @Test func aThreadOfOneQuestionKeepsItAndItsAnswerWhateverTheCap() async {
        let (store, _) = await hidden([F.user("Question", id: "u0"), F.assistant(String(repeating: "word ", count: 4_000), id: "a0")])
        store.releaseToTail(rows: 2, maxBytes: 1)
        #expect(store.keepsOnlyTail && store.messages.map(\.entryID) == ["u0", "a0"])
    }

    /// A release that cut nothing (the thread held no more than a tail) is still a release to the tail: the thread leaves the count of
    /// threads that hold their history, is bounded with the other tails, and comes back as a tail does, its eager tail alone and the
    /// lazy stack after its pull (`ThreadRestoreTests`). A thread of a few heavy replies is one, and that is the restore its first
    /// frame was measured with.
    @Test func aReleaseThatCutNothingStillLeavesTheThreadAsATail() async {
        let all = session(turns: 6)
        let (store, _) = await hidden(all)
        let rows = store.rows, cursor = store.olderCursor
        store.releaseToTail(rows: 30, maxBytes: .max)
        #expect(store.keepsOnlyTail && store.messages == all && store.rows == rows && store.olderCursor == cursor, "nothing was cut")
    }

    /// The first lazy stack of a thread that kept only its tail waits for the pull that catches it up (`ThreadRestore.waitsForPull`),
    /// and has no reason to wait for one that is not coming: it failed, pi is held off or did not start in time. A pi that is starting
    /// will answer, usually within seconds, so that is not a pull missed.
    @Test func aPullThatIsNotComingIsMarkedAsOneThatDoesNotCatchTheThreadUp() async {
        let (store, host) = await hidden(session(turns: 5))
        store.releaseToTail(rows: 30, maxBytes: .max)
        #expect(store.catchUp == nil && !store.catchUpFailed, "nothing has been asked yet")

        let failing = Task { await store.run(request: { _ in .failure(code: "unavailable", message: "The host cannot serve this thread.") }) }
        await until { store.loadError != nil }
        #expect(store.catchUp == nil && store.catchUpFailed && store.keepsOnlyTail)
        failing.cancel()
        store.suspend()
        #expect(!store.catchUpFailed, "the next run has not failed yet")

        host.starting = true
        var task = await start(store, host)
        #expect(store.starting && store.catchUp == nil && !store.catchUpFailed, "pi is starting: its snapshot is on its way")
        host.starting = false
        await store.refresh()
        #expect(store.catchUp != nil && !store.catchUpFailed && !store.starting, "the pull that lands catches it up")
        task.cancel()

        store.suspend()
        store.offline = true
        host.starting = true
        task = await start(store, host)
        #expect(store.catchUpFailed && !store.starting, "pi is held off: nothing is coming")
        store.suspend()
        #expect(!store.catchUpFailed && store.catchUp == nil)
        store.offline = false
        task.cancel()
        store.stop()
    }

    @Test func aPiThatDoesNotStartInTimeIsAPullThatDoesNotCatchTheThreadUp() async {
        let host = FakeHost(F.snapshot(messages: session(turns: 5)))
        let store = manualStore(startingLimit: .zero)
        var task = await start(store, host)
        task.cancel()
        store.suspend()
        store.releaseToTail(rows: 30, maxBytes: .max)

        host.starting = true
        task = await start(store, host)
        defer { task.cancel(); store.stop() }
        #expect(store.loadError != nil && store.catchUp == nil && store.catchUpFailed, "past the limit pi is not starting, it is in trouble")
    }

    @Test func aThreadOnScreenKeepsEverything() async {
        let host = FakeHost(F.snapshot(messages: session(turns: 100)))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel(); store.stop() }
        store.releaseToTail(rows: 30, maxBytes: 1)
        #expect(!store.keepsOnlyTail && store.messages.count == 200 && store.rows.count == 200)
    }

    @Test func releasingWholeStillLetsEverythingGo() async {
        let (store, _) = await hidden(session(turns: 10))
        store.releaseToTail(rows: 30, maxBytes: .max)
        #expect(store.keepsOnlyTail)
        store.release()
        #expect(!store.holdsHistory && !store.keepsOnlyTail && store.rows.isEmpty && store.retainedHistoryBytes == 0)
    }

    @Test func theCachesOfTheTurnsThatWentGoWithThem() async {
        let all = (0..<100).flatMap { turn in
            [F.user("Question \(turn)", id: "u\(turn)"), F.tool("bash", args: "{}", output: "out", id: "t\(turn)", callID: "c\(turn)"),
             F.assistant("Done \(turn).", thinking: "Thinking \(turn).", id: "a\(turn)")]
        }
        let (store, _) = await hidden(all)
        let calls = store.cachedCallCount, thinking = store.cachedThinkingCount
        #expect(calls == 100 && thinking == 100)
        store.releaseToTail(rows: 30, maxBytes: .max)
        #expect(store.cachedCallCount < calls / 2 && store.cachedCallCount > 0, "the calls of the rows that stay: \(store.cachedCallCount)")
        #expect(store.cachedThinkingCount < thinking / 2 && store.cachedThinkingCount > 0, "the thinking of the rows that stay: \(store.cachedThinkingCount)")
    }

    /// The agent went on while the thread was away: the first pull's page starts inside the tail, and only what is new is built.
    @Test func theFirstPullAfterTheReleaseLandsOverTheEndOfTheTailBuildingOnlyWhatIsNew() async {
        let all = session(turns: 100)
        let (store, host) = await hidden(all)
        store.releaseToTail(rows: 30, maxBytes: .max)
        let tail = store.rows
        #expect(!tail.isEmpty && store.catchUp == nil)

        let more = session(turns: 103)
        host.snapshot.messages = Array(more.suffix(50))
        host.snapshot.olderCursor = host.snapshot.messages.first?.entryID
        host.snapshot.revision = 2
        let projected = store.projectedRows, computed = store.rowCostComputations
        let task = await start(store, host)
        defer { task.cancel(); store.stop() }
        #expect(store.catchUp != nil && !store.keepsOnlyTail, "the pull landed, and the thread holds a page again")
        // The last row of the tail was the thread's last one, which offers Retry; it no longer is.
        #expect(Array(store.rows.prefix(tail.count - 1)) == Array(tail.dropLast()), "the rows it drew are the rows it has, with the same identities")
        #expect(store.rows[tail.count - 1].id == tail.last?.id)
        #expect(store.rows.last?.id == "u102/reply" && store.rows.count == tail.count + 6)
        #expect(store.projectedRows - projected <= 12, "only the new rows were built: \(store.projectedRows - projected) of \(store.rows.count)")
        #expect(store.rowCostComputations - computed <= 4, "and their replies: \(store.rowCostComputations - computed)")
    }

    /// A page longer than the tail: the older rows come in above it, and the rows of the tail stay as they are.
    @Test func aPullWhosePageReachesBeyondTheTailPutsOlderRowsAboveIt() async {
        let all = session(turns: 100)
        let (store, host) = await hidden(all)
        store.releaseToTail(rows: 30, maxBytes: .max)
        let tail = store.rows
        host.snapshot.messages = Array(all.suffix(100))
        host.snapshot.olderCursor = host.snapshot.messages.first?.entryID
        host.snapshot.revision = 2
        let computed = store.rowCostComputations
        let task = await start(store, host)
        defer { task.cancel(); store.stop() }
        #expect(store.rows.count == 100 && store.rows.suffix(tail.count).map(\.id) == tail.map(\.id))
        #expect(Array(store.rows.suffix(tail.count)) == tail)
        #expect(store.rowCostComputations - computed <= 30, "the rows of the tail kept their presentations: \(store.rowCostComputations - computed)")
        #expect(store.olderCursor == host.snapshot.olderCursor)
    }

    /// The cap cut the tail inside the host's newest page: the page the first pull brings starts before the tail, so it replaces the
    /// rows the thread holds (a new history), and the rows of the tail still keep their identities and what was derived for them.
    @Test func aPullWhosePageStartsBeforeATailTheCapCutKeepsTheRowsOfTheTailAsTheyWere() async {
        let all = session(turns: 100, text: String(repeating: "word ", count: 400))
        let (store, host) = await hidden(all)
        store.releaseToTail(rows: 30, maxBytes: store.retainedHistoryBytes / 40)
        let tail = store.rows
        #expect(store.keepsOnlyTail && !tail.isEmpty && store.messages.count < NativeThreadStore.releasedTailMessages,
                "the cap cut inside the host's newest page: \(store.messages.count) messages")

        host.snapshot.messages = Array(all.suffix(NativeThreadStore.releasedTailMessages))
        host.snapshot.olderCursor = host.snapshot.messages.first?.entryID
        host.snapshot.revision = 2
        let computed = store.rowCostComputations
        let task = await start(store, host)
        defer { task.cancel(); store.stop() }
        #expect(store.catchUp != nil && !store.keepsOnlyTail, "the pull landed, and the thread holds a page again")
        #expect(store.messages == host.snapshot.messages && store.olderCursor == host.snapshot.olderCursor)
        #expect(Array(store.rows.suffix(tail.count)) == tail, "the rows of the tail are the rows it had, with the same identities and presentations")
        // Only the rows the tail did not hold were derived: one reply for each of the turns above it.
        let above = (store.rows.count - tail.count) / 2
        #expect(store.rowCostComputations - computed <= above + 2, "\(store.rowCostComputations - computed) computed for \(above) turns above the tail")
    }

    @Test func aPullThatFindsNothingNewLeavesTheTailAsItIs() async {
        let host = FakeHost(F.snapshot(messages: session(turns: 100)))
        let store = manualStore()
        var task = await start(store, host, connection: "link")
        task.cancel()
        store.suspend()
        store.releaseToTail(rows: 30, maxBytes: .max)
        let rows = store.rows, messages = store.messages
        host.answersUnchanged = true
        task = await start(store, host, connection: "link")
        defer { task.cancel(); store.stop() }
        #expect(host.requests.suffix(1) == [.snapshot(expectedSessionID: "s", afterRevision: 1)], "the pull asks for what changed since")
        #expect(store.catchUp != nil && store.ready)
        #expect(store.rows == rows && store.messages == messages)
    }

    @Test func olderHistoryPagesInFromWhereTheTailStarts() async {
        let all = session(turns: 100)
        let (store, host) = await hidden(all)
        store.releaseToTail(rows: 30, maxBytes: .max)
        let cursor = store.olderCursor
        #expect(cursor == "u75")
        host.snapshot.messages = Array(all.suffix(50))
        host.snapshot.olderCursor = cursor
        host.snapshot.revision = 2
        let task = await start(store, host)
        defer { task.cancel(); store.stop() }
        #expect(store.messages.count == 50 && store.olderCursor == cursor)

        host.next = [.success(.snapshot(value: F.snapshot(messages: Array(all[100..<150]), olderCursor: "u50")))]
        await store.loadOlder()
        #expect(host.requests.last == .snapshot(expectedSessionID: "s", beforeEntryID: "u75"))
        #expect(store.messages.count == 100 && store.olderCursor == "u50" && !store.keepsOnlyTail)
        #expect(store.rows.count == 100)
    }
}

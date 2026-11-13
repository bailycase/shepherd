import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// Loaded history across Mac threads off screen: bounded by recency and bytes, never at the cost
/// of a draft, the selected thread, or a reader's place. And the rows their hidden views hold:
/// bounded by a budget, the history and the draft staying.
@Suite("Thread stores history budget")
@MainActor
struct NativeThreadStoresHistoryTests {
    private typealias Entry = NativeThreadStores<String>.HistoryEntry<String>

    @Test func releasesTheOldestUnpinnedPastTheCountAndTheBudget() {
        let entries = [Entry(key: "a", bytes: 10, pinned: false), Entry(key: "b", bytes: 10, pinned: true),
                       Entry(key: "c", bytes: 10, pinned: false), Entry(key: "d", bytes: 10, pinned: false)]
        #expect(NativeThreadStores<String>.evictions(entries, keep: 2, budget: 1_000) == ["a"])
        #expect(NativeThreadStores<String>.evictions(entries, keep: 8, budget: 25) == ["a", "c"])
        // Pinned threads alone over budget stay: the budget is exceeded rather than lose a reader's place.
        #expect(NativeThreadStores<String>.evictions([Entry(key: "b", bytes: 100, pinned: true)], keep: 0, budget: 1) == [])
    }

    /// `turns` question and answer pairs of `text` (one user message by default).
    private func snapshot(_ text: String, turns: Int? = nil) -> NativeThreadSnapshot {
        let messages = turns.map { turns in
            (0..<turns).flatMap { i in
                ["user", "assistant"].map { role in
                    NativeThreadMessage(entryID: "\(text)-\(role)-\(i)", role: role, blocks: [NativeThreadBlock(kind: .text, text: "\(text) \(role) \(i)")])
                }
            }
        } ?? [NativeThreadMessage(entryID: text, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)])]
        return NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false, supportedActions: [],
                                    dialogsSupported: true, dialogs: [], messages: messages, provisional: [], clipped: false)
    }

    @Test func evictionKeepsDraftsSelectionAndEachReadersPlace() {
        let stores = NativeThreadStores<String>()
        let pins = ThreadReaderPins()
        stores.pins = pins
        stores.retainedHistories = 0
        stores.protected = { ["selected"] }
        for key in ["a", "read", "selected", "newest"] {
            let store = stores.store(for: key)
            store.preview(snapshot(key))
            store.draft = "draft \(key)"
            stores.noteShown(key)
        }
        let reader = stores.store(for: "read")
        let deck = UUID(), second = UUID()
        pins.pin(reader, owner: deck)
        pins.pin(reader, owner: second)
        // One of two readers leaves: the other's place is still kept.
        pins.unpin(reader, owner: deck)
        stores.enforceHistoryBounds()
        #expect(!stores.store(for: "a").holdsHistory)
        #expect(reader.holdsHistory)
        #expect(stores.store(for: "selected").holdsHistory)
        #expect(stores.store(for: "newest").holdsHistory, "the thread just shown is never released")
        for key in ["a", "read", "selected", "newest"] { #expect(stores.store(for: key).draft == "draft \(key)") }

        pins.unpin(reader, owner: second)
        stores.enforceHistoryBounds()
        #expect(!reader.holdsHistory)
        #expect(reader.draft == "draft read")
        #expect(stores.existing(for: "read") === reader, "the store and its identity stay")
    }

    // MARK: Hidden threads' row views

    private typealias Mounted = NativeThreadStores<String>.MountedEntry<String>

    /// A pause that never ends until the test lets it, so a pass the stores schedule runs only when a test runs it.
    @MainActor private final class Pauses {
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func pause(_ duration: Duration) async {
            await withCheckedContinuation { waiting.append($0) }
        }

        func end() {
            let ended = waiting
            waiting = []
            for continuation in ended { continuation.resume() }
        }
    }

    /// Stores for `keys` whose threads each hold one turn, all mounted, with `selected` on screen, shown in order.
    private func mountedStores(_ keys: [String], selected: String, pauses: Pauses, turns: Int? = nil) -> NativeThreadStores<String> {
        let stores = NativeThreadStores<String>()
        stores.pause = { await pauses.pause($0) }
        stores.mounted = { Set(keys) }
        stores.protected = { [selected] }
        for key in keys {
            let store = stores.store(for: key)
            store.preview(snapshot(key, turns: turns))
            store.draft = "draft \(key)"
            stores.noteShown(key)
        }
        return stores
    }

    @Test func viewReleasesTakeUnpinnedThenOlderPinnedPastTheBudget() {
        // Oldest first, a hundred bytes each; b, d and e are readers left scrolled up.
        let entries = [Mounted(key: "a", cost: 100, pinned: false), Mounted(key: "b", cost: 100, pinned: true),
                       Mounted(key: "c", cost: 100, pinned: false), Mounted(key: "d", cost: 100, pinned: true),
                       Mounted(key: "e", cost: 100, pinned: true), Mounted(key: "f", cost: 100, pinned: false),
                       Mounted(key: "g", cost: 100, pinned: false)]
        func releases(_ entries: [Mounted] = entries, keep: Int = 1, keepPinned: Int = 2, budget: Int) -> [String] {
            NativeThreadStores<String>.viewReleases(entries, keep: keep, keepPinned: keepPinned, budget: budget)
        }
        #expect(releases(budget: 700) == [], "at the budget nothing goes")
        #expect(releases(budget: 500) == ["a", "c"], "the oldest unpinned first, and only as many as it takes")
        #expect(releases(budget: 100) == ["a", "c", "f", "b"], "then the readers older than the two most recent (d, e); the newest hidden (g) never")
        #expect(releases(budget: 0) == ["a", "c", "f", "b"], "whatever the budget")
        #expect(releases(keep: 0, keepPinned: 0, budget: 0) == ["a", "c", "f", "g", "b", "d", "e"], "with nothing kept every hidden thread goes, readers last")
        #expect(releases(keep: 0, budget: 0) == ["a", "c", "f", "g", "b"], "no newest kept: g goes, and the two most recent readers still stay")
        // The newest hidden thread is a reader: it is never taken, and counts among the two most recent readers.
        var newestReads = entries
        newestReads[6] = Mounted(key: "g", cost: 100, pinned: true)
        #expect(releases(newestReads, budget: 0) == ["a", "c", "f", "b", "d"])
        #expect(releases([], budget: 0) == [])
        // A thread at its last screen counts against the budget but has no more rows to give: the next one goes in its place.
        var atFloor = entries
        atFloor[0] = Mounted(key: "a", cost: 100, pinned: false, releasable: false)
        #expect(releases(atFloor, budget: 500) == ["c", "f"], "a is skipped and still counted: two others go")
        #expect(releases(atFloor, budget: 0) == ["c", "f", "b"])
        #expect(releases(entries.map { Mounted(key: $0.key, cost: $0.cost, pinned: $0.pinned, releasable: false) }, budget: 0) == [], "nothing at all to give")
    }

    @Test func theDefaultMountedBudgetIsAGigabyteOnEightAndTwoFromSixteen() {
        let gigabyte: UInt64 = 1 << 30
        #expect(NativeThreadStores<String>.defaultMountedBudget(physicalMemory: 8 * gigabyte) == Int(gigabyte))
        #expect(NativeThreadStores<String>.defaultMountedBudget(physicalMemory: 16 * gigabyte) == 2 * Int(gigabyte))
        #expect(NativeThreadStores<String>.defaultMountedBudget(physicalMemory: 128 * gigabyte) == 2 * Int(gigabyte))
    }

    @Test func aPassReleasesOneThreadDownToItsLastScreenAndKeepsItsHistory() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        stores.releaseStep = .max
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        let rows = a.rows, messages = a.messages, cost = a.mountedCost(eagerRows: stores.eagerRows)
        let kept = a.mountedCost(eagerRows: a.keptRows)
        #expect(cost > 0 && rows.count == 12 && a.keptRows == 4 && kept > 0 && kept < cost)

        let first = stores.enforceMountedBudget(budget: 0)
        #expect(first.threads == 1 && first.bytes == cost - kept, "the oldest hidden thread goes, alone, and not its last screen")
        #expect(a.transcriptReleased && a.transcriptDrawn == a.keptRows && a.holdsHistory, "its history stays")
        #expect(a.rows == rows && a.messages == messages && a.draft == "draft a" && stores.existing(for: "a") === a)
        #expect(a.mountedCost(eagerRows: stores.eagerRows) == kept, "it holds its last screen now")
        #expect(!b.transcriptReleased, "one thread a pass")

        #expect(stores.enforceMountedBudget(budget: 0).threads == 1)
        #expect(b.transcriptDrawn == b.keptRows && b.holdsHistory && b.draft == "draft b")
        #expect(stores.enforceMountedBudget(budget: 0) == (0, 0), "the newest hidden thread and the selected one are never taken, and a and b have nothing more to give")
        #expect(!stores.store(for: "c").transcriptReleased && !stores.store(for: "d").transcriptReleased)
        #expect(stores.enforceMountedBudget(budget: 0, keep: 0).threads == 1, "with none kept, the newest goes too")
        #expect(stores.store(for: "c").transcriptReleased && !stores.store(for: "d").transcriptReleased, "the selected thread stays")
    }

    @Test func aPassWaitsWhileThePersonIsAtWork() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        stores.releaseStep = .max
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        #expect(stores.busy == nil && NativeThreadStores<String>().busy == nil, "nothing tells a store's passes to wait unless the app does")
        stores.mountedBudget = 0
        #expect(a.transcriptDrawn == a.keptRows && b.transcriptDrawn == nil, "a budget over a pass: the oldest thread goes")

        var wait = ThreadPassWait.input
        stores.busy = { wait }
        #expect(stores.runMountedPass() == false, "typing or scrolling: the pass looks again later")
        wait = .streaming
        #expect(stores.runMountedPass() == false, "or a reply streaming in")
        #expect(b.transcriptDrawn == nil, "and takes nothing")
        wait = .idle
        #expect(stores.runMountedPass() == true)
        #expect(b.transcriptDrawn == b.keptRows, "once it is quiet, it runs")
    }

    /// Typing and scrolling hold a pass off for as long as they last, however many times it looks: it never runs in the middle of a keystroke.
    @Test func aPassNeverRunsWhileThePersonTypesOrScrolls() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        stores.releaseStep = .max
        stores.patience = 3
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        stores.mountedBudget = 0
        #expect(a.transcriptDrawn == a.keptRows && b.transcriptDrawn == nil)

        stores.busy = { .input }
        for look in 1...20 {
            #expect(stores.runMountedPass() == false && b.transcriptDrawn == nil, "look \(look): it waits, patience or not")
        }
        stores.busy = { .idle }
        #expect(stores.runMountedPass() == true && b.transcriptDrawn == b.keptRows, "and runs once the person stops")
    }

    @Test func aThreadOnScreenStreamsWhenItsVersionMovesBetweenTwoLooks() {
        let stream = UserActivity.Stream()
        let (one, two) = (NSObject(), NSObject())
        let (a, b) = (ObjectIdentifier(one), ObjectIdentifier(two))
        defer { withExtendedLifetime((one, two)) {} }
        #expect(!stream.changed([:]), "nothing is shown")
        #expect(!stream.changed([a: 7]), "the first look has nothing to compare with")
        #expect(!stream.changed([a: 7]), "unchanged between two looks")
        #expect(stream.changed([a: 8]), "a chunk came in")
        #expect(!stream.changed([a: 8]))
        #expect(!stream.changed([:]) && !stream.changed([a: 9]), "a thread shown after another is a first look again")
        #expect(!stream.changed([a: 9, b: 1]), "a second thread coming on screen is a first look too")
        #expect(stream.changed([a: 9, b: 2]), "and any one of those on screen streaming counts, a local thread's or a remote's")
    }

    @Test func theShownVersionsAreTheOnesOnScreenAndSelected() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c"], selected: "c", pauses: pauses, turns: 2)
        let shown = stores.shownVersions()
        #expect(shown.count == 1 && shown[ObjectIdentifier(stores.store(for: "c"))] == stores.store(for: "c").threadVersion, "the selected thread, which no view marks live here")
    }

    @Test func aPassWaitsForAThreadThatStreamsOnlyAWhile() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        stores.releaseStep = .max
        stores.patience = 3
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        stores.mountedBudget = 0
        #expect(a.transcriptDrawn == a.keptRows && b.transcriptDrawn == nil)

        stores.busy = { .streaming }
        for look in 1...3 {
            #expect(stores.runMountedPass() == false && b.transcriptDrawn == nil, "look \(look): it waits")
        }
        #expect(stores.runMountedPass() == true && b.transcriptDrawn == b.keptRows, "and then it runs, however long the stream goes on")
        #expect(stores.runMountedPass() == false, "the one after waits as long again")
    }

    /// Only looks at a stream use up the patience: the person typing in between neither adds to it nor ends the wait.
    @Test func typingDoesNotUseUpThePatienceAStreamIsOwed() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        stores.releaseStep = .max
        stores.patience = 3
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        stores.mountedBudget = 0
        #expect(a.transcriptDrawn == a.keptRows && b.transcriptDrawn == nil)

        var wait = ThreadPassWait.streaming
        stores.busy = { wait }
        for _ in 1...2 { #expect(stores.runMountedPass() == false) }
        wait = .input
        for _ in 1...10 { #expect(stores.runMountedPass() == false, "typing: it waits, and keeps count of the stream") }
        wait = .streaming
        #expect(stores.runMountedPass() == false && b.transcriptDrawn == nil, "the third look at the stream is the last it waits for")
        #expect(stores.runMountedPass() == true && b.transcriptDrawn == b.keptRows, "and the fourth runs")
    }

    /// A pass lets go of rows a step at a time, and a step is a row or the bytes the stores give it, whichever is more.
    @Test func aPassTakesNoMoreThanAStepOfRows() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c"], selected: "c", pauses: pauses, turns: 8)
        let a = stores.store(for: "a")
        let one = a.mountedCost(eagerRows: 1)
        stores.eagerRows = 8
        stores.releaseStep = one
        let first = stores.enforceMountedBudget(budget: 0)
        #expect(first.threads == 1 && a.transcriptDrawn == 8, "the first pass takes the lazy stack's rows")
        var drawn = a.transcriptDrawn ?? 0
        while a.canReleaseTranscript {
            let pass = stores.enforceMountedBudget(budget: 0)
            #expect(pass.threads == 1 && pass.bytes <= one * 2, "a step of the bytes it was given (a row is as many): \(pass.bytes) of \(one)")
            #expect(a.transcriptDrawn.map { $0 < drawn } == true)
            drawn = a.transcriptDrawn ?? 0
        }
        #expect(drawn == a.keptRows)
    }

    @Test func aPassLetsGoOfOneThreadInStepsBeforeItTakesTheNext() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c"], selected: "c", pauses: pauses, turns: 6)
        stores.eagerRows = 8
        stores.releaseStep = 1
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        let rows = a.rows, messages = a.messages
        #expect(rows.count == 12 && a.mountedCost(eagerRows: 8) > 0 && a.keptRows == 4)

        var left = a.mountedCost(eagerRows: 8)
        let first = stores.enforceMountedBudget(budget: 0, keep: 0)
        #expect(first.threads == 1 && a.transcriptDrawn == 8, "the first pass takes the lazy stack's rows")
        #expect(a.mountedCost(eagerRows: 8) == left, "which are not in the estimate")
        for drawn in stride(from: 7, through: 4, by: -1) {
            let pass = stores.enforceMountedBudget(budget: 0, keep: 0)
            #expect(pass.threads == 1 && a.transcriptDrawn == drawn, "each pass after takes the oldest row it still draws")
            #expect(pass.bytes == left - a.mountedCost(eagerRows: 8) && pass.bytes > 0, "and reports what that was")
            left = a.mountedCost(eagerRows: 8)
            #expect(b.transcriptDrawn == nil, "the next thread waits")
        }
        #expect(left == a.mountedCost(eagerRows: a.keptRows) && a.holdsHistory && a.rows == rows && a.messages == messages && a.draft == "draft a", "a keeps its last screen")
        #expect(stores.enforceMountedBudget(budget: 0, keep: 0).threads == 1 && b.transcriptDrawn == 8, "then the next thread's turn, a having no more to give")
        let unlimited = stores.enforceMountedBudget(budget: 0, keep: 0, limit: .max, step: .max)
        #expect(unlimited.threads == 1 && b.transcriptDrawn == 4, "a step of everything lets all of a thread but its last screen go in one")
    }

    @Test func aBudgetReachedHalfwayThroughAThreadStopsThere() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c"], selected: "c", pauses: pauses, turns: 6)
        stores.eagerRows = 8
        stores.releaseStep = 1
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        let heldByB = b.mountedCost(eagerRows: 8)
        // Room for all of b and three quarters of a.
        let budget = heldByB + a.mountedCost(eagerRows: 8) * 3 / 4
        for _ in 0..<12 { stores.enforceMountedBudget(budget: budget, keep: 1) }
        #expect(a.transcriptDrawn.map { $0 > a.keptRows } == true && a.mountedCost(eagerRows: 8) + heldByB <= budget, "a gave up rows until what is held fits, and no more")
        #expect(b.transcriptDrawn == nil, "b is the newest hidden thread, and never taken")
    }

    @Test func aBudgetAboveWhatTheHiddenThreadsHoldReleasesNothing() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        let held = ["a", "b", "c"].reduce(0) { $0 + stores.store(for: $1).mountedCost(eagerRows: stores.eagerRows) }
        #expect(stores.enforceMountedBudget(budget: held, limit: .max) == (0, 0))
        #expect(stores.enforceMountedBudget(budget: held - 1, limit: .max).threads == 1, "one byte over takes the oldest")
        let none = NativeThreadStores<String>()
        none.store(for: "a").preview(snapshot("a", turns: 6))
        #expect(none.enforceMountedBudget(budget: 0, keep: 0, limit: .max) == (0, 0), "stores nothing mounts have no views to release")
        #expect(!none.store(for: "a").transcriptReleased)
    }

    @Test func readersGoOnlyBeyondTheTwoMostRecentlyShown() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d", "e", "f"], selected: "f", pauses: pauses, turns: 6)
        let pins = ThreadReaderPins()
        stores.pins = pins
        for key in ["a", "b", "c", "d", "e"] { pins.pin(stores.store(for: key), owner: UUID()) }

        let taken = stores.enforceMountedBudget(budget: 0, limit: .max)
        #expect(taken.threads == 3)
        for key in ["a", "b", "c"] { #expect(stores.store(for: key).transcriptReleased, "\(key) is a reader older than the two most recent") }
        for key in ["d", "e", "f"] { #expect(!stores.store(for: key).transcriptReleased, "\(key) stays") }
    }
}

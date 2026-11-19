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
        #expect(stores.store(for: "a").keepsOnlyTail, "a thread past the bounds keeps only its tail")
        #expect(reader.holdsHistory && !reader.keepsOnlyTail)
        #expect(stores.store(for: "selected").holdsHistory)
        #expect(stores.store(for: "newest").holdsHistory, "the thread just shown is never released")
        for key in ["a", "read", "selected", "newest"] { #expect(stores.store(for: key).draft == "draft \(key)") }

        pins.unpin(reader, owner: second)
        stores.enforceHistoryBounds()
        #expect(reader.keepsOnlyTail)
        #expect(reader.draft == "draft read")
        #expect(stores.existing(for: "read") === reader, "the store and its identity stay")
    }

    /// A thread past the bounds lets its older history go and keeps its tail: what it draws first when it is shown again.
    @Test func aThreadPastTheBoundsKeepsItsTailRows() {
        let stores = NativeThreadStores<String>()
        stores.retainedHistories = 0
        stores.protected = { ["newest"] }
        let old = stores.store(for: "old")
        old.preview(snapshot("old", turns: 100))
        stores.store(for: "newest").preview(snapshot("newest"))
        stores.noteShown("old")
        stores.noteShown("newest")
        let rows = old.rows, messages = old.messages
        #expect(rows.count == 200)

        stores.enforceHistoryBounds()
        #expect(!old.rows.isEmpty && old.rows.count < rows.count, "older rows go, the tail stays: \(old.rows.count) of \(rows.count)")
        #expect(old.rows.suffix(30) == rows.suffix(30), "the tail is the rows it had, with the same identities")
        #expect(old.messages.last == messages.last && old.messages.count < messages.count)
        #expect(old.olderCursor == old.messages.first?.entryID, "older history pages in from where the tail starts")
        #expect(old.draft == "" && stores.existing(for: "old") === old)
    }

    /// More threads than the budget of tails holds: the ones shown longest ago go whole, and what is kept stays within the budget.
    @Test func tailsPastTheirBudgetGoWholeOldestFirst() {
        let stores = NativeThreadStores<String>()
        stores.retainedHistories = 0
        let keys = ["a", "b", "c", "d", "e", "f"]
        for key in keys {
            stores.store(for: key).preview(snapshot(key, turns: 100))
            stores.noteShown(key)
        }
        stores.enforceHistoryBounds()
        let hidden = keys.dropLast().map { stores.store(for: $0) }
        #expect(hidden.allSatisfy { $0.keepsOnlyTail && !$0.rows.isEmpty }, "the default budget holds them all")
        #expect(!stores.store(for: "f").keepsOnlyTail && stores.store(for: "f").rows.count == 200, "the thread shown last is whole")

        let one = hidden[0].retainedHistoryBytes
        stores.tailBudget = one * 3 + one / 2
        stores.enforceHistoryBounds()
        for key in ["a", "b"] {
            let store = stores.store(for: key)
            #expect(!store.holdsHistory && store.rows.isEmpty && !store.keepsOnlyTail, "\(key) was shown longest ago: it goes whole")
        }
        let kept = ["c", "d", "e"].map { stores.store(for: $0) }
        #expect(kept.allSatisfy { $0.keepsOnlyTail && !$0.rows.isEmpty })
        #expect(kept.reduce(0) { $0 + $1.retainedHistoryBytes } <= stores.tailBudget, "what the tails hold is within the budget")
        #expect(stores.store(for: "a").draft == "" && stores.existing(for: "a") != nil)
    }

    /// One tail holds no more than its cap, but always the last question and its answer.
    @Test func aTailKeepsWithinItsCapAndAlwaysTheLastTurn() {
        let stores = NativeThreadStores<String>()
        stores.retainedHistories = 0
        let words = String(repeating: "word ", count: 2_000)
        let messages = (0..<60).flatMap { i in
            [NativeThreadMessage(entryID: "u\(i)", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Question \(i)")]),
             NativeThreadMessage(entryID: "a\(i)", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "\(words) \(i)")])]
        }
        var value = snapshot("big")
        value.messages = messages
        let big = stores.store(for: "big")
        big.preview(value)
        stores.store(for: "newest").preview(snapshot("newest"))
        stores.noteShown("big")
        stores.noteShown("newest")
        let before = big.retainedHistoryBytes

        stores.tailCap = before / 20
        stores.enforceHistoryBounds()
        #expect(big.keepsOnlyTail && big.retainedHistoryBytes <= stores.tailCap, "\(big.retainedHistoryBytes) of \(stores.tailCap)")
        #expect(big.rows.last?.id == "u59/reply" && big.messages.first?.role == "user" && big.rows.count >= 2, "the end of the thread stays")

        stores.tailCap = 1
        big.preview(value)
        stores.noteShown("big")
        stores.noteShown("newest")
        stores.enforceHistoryBounds()
        #expect(big.rows.count == 2 && big.rows.last?.id == "u59/reply", "under any cap, the last question and its answer: \(big.rows.count) rows")
    }

    /// A thread that holds no question (a page that starts inside one long reply) holds one agent turn, the last answer, which the rule
    /// keeps whatever it holds: past the bounds only what older pages added above the host's newest page is cut, and only over the cap.
    @Test func aThreadWithNoQuestionKeepsItsNewestPageWhateverTheCap() {
        let stores = NativeThreadStores<String>()
        stores.retainedHistories = 0
        let words = String(repeating: "word ", count: 2_000)
        func notes(_ count: Int, _ text: String) -> NativeThreadSnapshot {
            var value = snapshot("notes")
            value.messages = (0..<count).map { NativeThreadMessage(entryID: "a\($0)", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "\(text) \($0)")]) }
            return value
        }
        let paged = stores.store(for: "paged"), page = stores.store(for: "page"), within = stores.store(for: "within")
        paged.preview(notes(120, words))
        page.preview(notes(30, words + words + words + words))
        within.preview(notes(120, "Note"))
        stores.store(for: "newest").preview(snapshot("newest"))
        for key in ["paged", "page", "within", "newest"] { stores.noteShown(key) }
        let before = paged.retainedHistoryBytes, rows = within.rows

        stores.tailCap = before / 2
        stores.enforceHistoryBounds()
        #expect(paged.keepsOnlyTail && paged.messages.count == NativeThreadStore.releasedTailMessages && paged.retainedHistoryBytes <= stores.tailCap,
                "\(paged.retainedHistoryBytes) of \(stores.tailCap): the page the host sends")
        #expect(page.keepsOnlyTail && page.messages.count == 30 && page.retainedHistoryBytes > stores.tailCap, "one page is not cut, whatever it holds")
        #expect(within.keepsOnlyTail && within.rows == rows, "what fits the cap stays")
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

    @Test func overBudgetIsWhatAPassCanTakeAndNotWhatTheThreadsHold() {
        func over(_ entries: [Mounted], keepPinned: Int = 2, budget: Int) -> Int {
            NativeThreadStores<String>.overBudget(entries, keep: 1, keepPinned: keepPinned, budget: budget)
        }
        // Oldest first: b is a reader, kept as one of the two most recent; d, the newest, is never taken.
        let entries = [Mounted(key: "a", cost: 100, pinned: false), Mounted(key: "b", cost: 100, pinned: true),
                       Mounted(key: "c", cost: 100, pinned: false), Mounted(key: "d", cost: 400, pinned: false)]
        #expect(over(entries, budget: 700) == 0, "at the budget nothing")
        #expect(over(entries, budget: 600) == 100, "over by what the pass can take")
        #expect(over(entries, budget: 0) == 200, "the threads hold 700 over the budget and a pass can take a and c: not b, a reader kept, nor d, the newest")
        #expect(over(entries, keepPinned: 0, budget: 0) == 300, "a reader past the ones kept can go")
        #expect(over([Mounted(key: "a", cost: 100, pinned: false, releasable: false), Mounted(key: "b", cost: 900, pinned: false)], budget: 0) == 0,
                "the newest alone, and a thread with nothing more to give")
        #expect(over([], budget: 0) == 0)
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

    /// Showing a thread builds its rows again, hundreds of megabytes of them in a few seconds, and the time before the next show gives the
    /// passes a few looks: a pass that took a step of one thread however far over the budget the threads were never caught up with the shows.
    @Test func aPassFarOverTheBudgetLetsGoOfWhatItIsOverByWhenTheAppIsQuiet() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d", "e", "f"], selected: "f", pauses: pauses, turns: 6)
        stores.releaseStep = stores.store(for: "a").mountedCost(eagerRows: 1)
        stores.busy = { .idle }
        stores.mountedBudget = 0
        #expect(stores.runMountedPass() == true)
        for key in ["a", "b", "c", "d"] {
            let store = stores.store(for: key)
            #expect(store.transcriptDrawn == store.keptRows, "\(key) is down to its last screen after one pass: it was far over")
        }
        #expect(!stores.store(for: "e").transcriptReleased, "the newest hidden thread stays")
    }

    /// A quiet pass takes what the threads are over by, no more than the ceiling (a row over at the most, the row that crosses it goes), and a
    /// pass while a thread streams, the step.
    @Test func aQuietPassTakesNoMoreThanTheCeilingAndAStreamingOneNoMoreThanAStep() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d", "e", "f"], selected: "f", pauses: pauses, turns: 6)
        let b = stores.store(for: "b")
        let row = stores.store(for: "a").mountedCost(eagerRows: 1)
        func hidden() -> Int { ["a", "b", "c", "d", "e"].reduce(0) { $0 + stores.store(for: $1).mountedCost(eagerRows: stores.eagerRows) } }
        let whole = hidden()
        stores.releaseStep = row
        stores.patience = 1
        stores.mountedBudget = 0
        var wait = ThreadPassWait.streaming
        stores.busy = { wait }
        let afterBudget = hidden()
        #expect(afterBudget < whole, "setting the budget runs a pass of a step")
        #expect(stores.runMountedPass() == false, "a stream: it waits its looks")
        #expect(stores.runMountedPass() == true)
        let streaming = afterBudget - hidden()
        #expect(streaming > 0 && streaming <= row * 2 && b.transcriptDrawn == nil, "a stream gives it a step, a row over at the most, of one thread: \(streaming) of \(row)")

        // Over the budget by more than the ceiling and not far over: the ceiling is what it takes.
        wait = .idle
        stores.releaseCeiling = row
        stores.mountedBudget = hidden() - row * 7 / 2
        let over = hidden() - stores.mountedBudget
        #expect(over > stores.releaseCeiling && !stores.farOverBudget(), "over by \(over), a ceiling of \(row), not far over")
        let before = hidden()
        #expect(stores.runMountedPass() == true)
        let quiet = before - hidden()
        #expect(quiet > 0 && quiet <= row * 2 && quiet < over, "a quiet pass takes the ceiling, a row over at the most: \(quiet) of \(row), over by \(over)")
    }

    /// A step that lets go of a thread's lazy stack costs a layout of its whole host: a quiet pass lets go of one lazy stack and goes on to the
    /// rows after it, which a pass that only waited for its turn would have taken a pass later; any other pass takes the lazy stack alone.
    @Test func aQuietPassLetsGoOfOneLazyStackAndTheRowsAfterIt() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 8)
        stores.eagerRows = 8
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        #expect(a.rows.count == 16 && a.transcriptDrawn == nil && b.transcriptDrawn == nil)
        #expect(stores.enforceMountedBudget(budget: 0, limit: .max, ceiling: stores.releaseCeiling).threads == 1)
        #expect(a.transcriptDrawn == a.keptRows, "a's lazy stack and its rows, in one pass")
        #expect(b.transcriptDrawn == nil, "b's lazy stack waits for the next pass")
        #expect(stores.enforceMountedBudget(budget: 0, limit: .max, ceiling: stores.releaseCeiling).threads == 1 && b.transcriptDrawn == b.keptRows)
    }

    /// A step of everything lets go of the lazy stack with the rows, thread after thread: the room it has left after one is still everything.
    @Test func aStepOfEverythingTakesEveryThreadDownToItsLastScreenInOnePass() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 8)
        stores.eagerRows = 8
        #expect(stores.enforceMountedBudget(budget: 0, keep: 0, limit: .max, step: .max).threads == 3)
        for key in ["a", "b", "c"] {
            let store = stores.store(for: key)
            #expect(store.transcriptDrawn == store.keptRows, "\(key) goes whole, a lazy stack and all")
        }
    }

    /// Far over the budget, more rows are built by the shows meanwhile than the passes let go of in the seconds a stream lasts: typing still holds a
    /// pass off, a stream no longer does, and the pass that runs lets go of the ceiling at most, as much as a quiet pass of a thread near the budget:
    /// the stream it runs beside stalls no longer than that.
    @Test func aStreamHoldsNoPassOffOnceTheThreadsAreFarOverTheBudget() {
        let pauses = Pauses()
        defer { pauses.end() }
        let keys = ["a", "b", "c", "d", "e", "f"]
        let stores = mountedStores(keys, selected: "f", pauses: pauses, turns: 6)
        let row = stores.store(for: "a").mountedCost(eagerRows: 1)
        func hidden() -> Int { keys.dropLast().reduce(0) { $0 + stores.store(for: $1).mountedCost(eagerRows: stores.eagerRows) } }
        let held = hidden()
        stores.releaseStep = row
        stores.releaseCeiling = row * 2
        var wait = ThreadPassWait.streaming
        stores.busy = { wait }
        stores.mountedBudget = held - row
        #expect(!stores.farOverBudget(), "a row over is not far over")
        #expect(stores.runMountedPass() == false, "a stream holds a pass off while the threads are about at the budget")

        stores.mountedBudget = held / 3
        let over = hidden() - stores.mountedBudget
        #expect(stores.farOverBudget() && over > row * 8, "far over, by more than the ceiling of two rows many times: \(over) of \(row)")
        let before = hidden()
        #expect(stores.runMountedPass() == true, "far over, a stream holds none off")
        let taken = before - hidden()
        #expect(taken > 0 && taken <= row * 3, "the ceiling at most, a row over at the most, and not what they are over by: \(taken) of \(row), over by \(over)")
        wait = .input
        #expect(stores.runMountedPass() == false, "typing holds it off all the same")
    }

    /// The newest hidden thread is never taken, a reader kept or a thread at its last screen has nothing to give, so what they hold is
    /// no part of what a pass has to catch up with: far over is what a pass can take, not what the threads hold over the budget.
    @Test func memoryNoPassCanTakeIsNotFarOverTheBudget() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c"], selected: "c", pauses: pauses, turns: 6)
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        let row = a.mountedCost(eagerRows: 1)
        a.releaseTranscript(keepingLastScreen: true)
        #expect(!a.canReleaseTranscript && b.canReleaseTranscript)
        stores.releaseCeiling = row
        stores.releaseStep = row
        stores.busy = { .streaming }
        stores.mountedBudget = 0
        let held = a.mountedCost(eagerRows: stores.eagerRows) + b.mountedCost(eagerRows: stores.eagerRows)
        #expect(held > max(stores.mountedBudget / 4, stores.releaseCeiling), "the hidden threads hold more than the far-over threshold: \(held) of \(row)")
        #expect(!stores.farOverBudget(), "b is the newest hidden thread and a has nothing more to give")
        #expect(stores.runMountedPass() == false, "a stream still holds the pass off, as it is owed to do")
    }

    /// The looks while the person types or scrolls read nothing, and a pass reads the hidden threads once, however it decides what to do.
    @Test func aPassReadsTheHiddenThreadsOnceAndALookWhileTypingNotAtAll() {
        let pauses = Pauses()
        defer { pauses.end() }
        let keys = ["a", "b", "c", "d"]
        let stores = mountedStores(keys, selected: "d", pauses: pauses, turns: 6)
        var reads = 0
        stores.mounted = {
            reads += 1
            return Set(keys)
        }
        stores.mountedBudget = 0
        reads = 0
        var wait = ThreadPassWait.input
        stores.busy = { wait }
        #expect(stores.runMountedPass() == false && reads == 0, "typing: a look reads nothing, read \(reads) times")
        wait = .streaming
        #expect(stores.runMountedPass() == false && reads == 1, "a stream's look reads them once, read \(reads) times")
        reads = 0
        wait = .idle
        #expect(stores.runMountedPass() == true && reads == 1, "a pass reads them once, read \(reads) times")
    }

    /// A stream's pass after its patience lasted, with the threads not far over, is one thread's step and no more: it does not go on to the
    /// threads after it with what that one left of the step.
    @Test func aStreamsPassAfterItsPatienceTakesOneThread() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        let row = a.mountedCost(eagerRows: 1)
        stores.releaseStep = row
        stores.patience = 1
        stores.busy = { .streaming }
        stores.mountedBudget = 0
        stores.releaseStep = row * 40
        #expect(!stores.farOverBudget(), "the ceiling is more than the threads hold")
        #expect(a.transcriptDrawn != nil && b.transcriptDrawn == nil, "setting the budget took a row of a")
        #expect(stores.runMountedPass() == false)
        #expect(stores.runMountedPass() == true)
        #expect(a.transcriptDrawn == a.keptRows && b.transcriptDrawn == nil, "a, down to its last screen with the step to spare: b waits for the next pass")
    }

    /// Far over the budget the pass of a quiet app lets go of what they are over by too, not only the quiet ceiling's: the one that took a
    /// row between two steps of a restore that builds one never caught up with it.
    @Test func aQuietPassFarOverTheBudgetLetsGoOfMoreThanTheCeiling() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        let row = stores.store(for: "a").mountedCost(eagerRows: 1)
        let held = ["a", "b", "c"].reduce(0) { $0 + stores.store(for: $1).mountedCost(eagerRows: stores.eagerRows) }
        func hidden() -> Int { ["a", "b", "c"].reduce(0) { $0 + stores.store(for: $1).mountedCost(eagerRows: stores.eagerRows) } }
        stores.releaseStep = row
        stores.releaseCeiling = row * 3
        stores.busy = { .idle }
        stores.mountedBudget = held - row * 6
        #expect(!stores.farOverBudget(), "six rows over, with a ceiling of three, is not far over")
        var before = hidden()
        #expect(stores.runMountedPass() == true)
        #expect(before - hidden() <= row * 4, "near the budget a pass takes the ceiling at most: \(before - hidden()) of \(row)")
        stores.mountedBudget = 0
        #expect(stores.farOverBudget())
        before = hidden()
        #expect(stores.runMountedPass() == true)
        #expect(before - hidden() > row * 5, "far over it takes what they are over by: \(before - hidden()) of \(row)")
    }

    /// A step that crosses goes on to the row that does not fit, so that it is not spent on small rows ahead of a large one.
    @Test func aStepThatCrossesLetsGoOfTheRowThatDoesNotFit() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c"], selected: "c", pauses: pauses, turns: 6)
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        let count = a.rows.count
        let oldest = a.mountedCost(eagerRows: count) - a.mountedCost(eagerRows: count - 1)
        let next = a.mountedCost(eagerRows: count - 1) - a.mountedCost(eagerRows: count - 2)
        #expect(oldest > 0 && next > 0 && b.rows.count == count)
        let bytes = oldest + next - 1
        a.releaseTranscript(bytes: bytes)
        #expect(a.transcriptDrawn == count - 1, "one byte short of two rows takes one")
        b.releaseTranscript(bytes: bytes, crossing: true)
        #expect(b.transcriptDrawn == count - 2, "crossing takes the second, which does not fit")
    }

    /// A stream never holds the passes off for good: after the default patience (forty looks, ten seconds at the default spacing) a pass runs.
    @Test func aStreamHoldsAPassOffForTenSecondsAtMost() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses, turns: 6)
        #expect(stores.releaseSpacing * stores.patience == .seconds(10))
        stores.busy = { .streaming }
        let b = stores.store(for: "b")
        stores.mountedBudget = 0
        for look in 1...stores.patience { #expect(stores.runMountedPass() == false && b.transcriptDrawn == nil, "look \(look): a stream holds it off") }
        #expect(stores.runMountedPass() == true && b.transcriptReleased, "and the next look runs, whatever else streams")
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

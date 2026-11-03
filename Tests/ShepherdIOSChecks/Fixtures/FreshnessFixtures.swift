import Foundation
import SwiftUI
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The November mobile audit's surfaces: Home's lazy Pinned card with many pins, a thread while
// its host reconnects and while it is offline (one line and one button in the same place), and
// iPad thread switches that flip visibility instead of remounting.
extension FixtureCatalog {
    static var freshness: [FixtureScreen] {
        let preview = FixtureData.ref(FixtureData.preview)
        return [
            FixtureScreen(name: "home-pins-many", hosts: FreshnessFixtures.manyThreads(50), prepare: FreshnessFixtures.pinAll),
            FixtureScreen(name: "thread-reconnecting", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FreshnessFixtures.reconnecting),
            FixtureScreen(name: "thread-offline", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FreshnessFixtures.offline),
            // The real ReviewStore over large files: what it holds, letting it go off screen, and a
            // fetch that a shed overtakes. Checks only; its shot is the thread.
            FixtureScreen(name: "review-retention", hosts: ReviewRetentionFixture.hosts(), routes: [.thread(preview)],
                          prepare: ReviewRetentionFixture.run),
            FixtureScreen(name: "review-preparation-cancellation", hosts: ChangesFixture.hosts(), routes: [.thread(preview)],
                          prepare: ReviewPreparationFixture.run),
            // UX-02: a refused send kept with its image, restored only into an empty composer, a
            // newer draft and image kept, an unknown outcome never restorable. Shot: both banners.
            FixtureScreen(name: "composer-refused", hosts: RefusedSendFixture.hosts(), routes: [.thread(preview)],
                          prepare: RefusedSendFixture.run),
            // An earlier launch's kept sends (seeded before the app starts): text only, refused one
            // restorable, unknown one not.
            FixtureScreen(name: "composer-recovered", hosts: RefusedSendFixture.recoveredHosts(), routes: [.thread(preview)],
                          prepare: RefusedSendFixture.recovered),
            FixtureScreen(name: "pad-switch", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FreshnessFixtures.switchThreads),
            // Run with -w: a thread kept hidden in one window and shown in a second, which then closes.
            // Run with -w on iPad: one thread in two real windows sharing its store and composer
            // state: a held send, typing in the other window, restore protection, reconnect, forget.
            // Its shot is taken with both windows still open (the front one drawn).
            FixtureScreen(name: "windows-composer", hosts: TwoWindowFixture.hosts(), routes: [.thread(preview)],
                          prepare: { await TwoWindowFixture.run($0, forget: false) }),
            // The same, then Forget: checks only (its shot is of no window).
            FixtureScreen(name: "windows-composer-forget", hosts: TwoWindowFixture.hosts(), routes: [.thread(preview)],
                          prepare: { await TwoWindowFixture.run($0, forget: true) }),
            FixtureScreen(name: "windows-deck-close", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FreshnessFixtures.closeWindow),
        ]
    }
}

@MainActor enum FreshnessFixtures {
    static func check(_ ok: Bool, _ what: String) {
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)")
        fflush(stdout)
    }

    /// One host with `count` idle threads, each with a long-ish name.
    static func manyThreads(_ count: Int) -> [FixtureHostData] {
        let agents = (1...count).map { index in
            FixtureData.agent(AgentID(rawValue: "pin-\(index)"), "Pinned thread \(index) · tidy the ledger exports before release", .idle)
        }
        return [FixtureHostData(id: FixtureData.studio, name: "Studio", state: ShepherdState(spaces: [FixtureData.shepherdSpace], agents: agents))]
    }

    /// Pins every thread, then counts the Pinned card's rows built: the card is lazy, so far
    /// fewer than 50 at a phone's height.
    static func pinAll(_ app: MobileApp) async {
        await HomeFeed.of(app.hosts).refresh()
        let sidebar = SidebarThreads.of(app.hosts)
        SHRenderProbe.start()
        for agent in app.hosts.hosts[0].state.agents { sidebar.togglePin(AgentRef(host: FixtureData.studio, agent: agent.id)) }
        try? await Task.sleep(for: .seconds(1))
        let built = SHRenderProbe.stop()["listCard.segment", default: 0]
        check(sidebar.groups(HomeFeed.of(app.hosts).model).pinned.count == 50, "all 50 pins are in the group")
        check(built > 0 && built < 50, "the Pinned card built \(built) of 50 rows")
    }

    /// The thread on screen; then its host's next hello goes unanswered and the app reconnects.
    static func reconnecting(_ app: MobileApp) async {
        FixtureHost.running(FixtureData.studio)?.holdHello()
        app.hosts.retry(FixtureData.studio)
        await FixtureWindows.wait("connecting", seconds: 5) { app.hosts.host(FixtureData.studio)?.phase == .connecting }
        try? await Task.sleep(for: .milliseconds(500))
        SidebarAutomationsCheck.enableAccessibility()
        try? await Task.sleep(for: .seconds(1))
        let labels = SidebarAutomationsCheck.labels()
        check(labels.contains { $0.hasPrefix("Reconnecting to Studio") }, "the notice says it is reconnecting")
        check(labels.contains("Connecting…") && !labels.contains("Retry connection"), "the button waits while a try is under way")
        check(!labels.contains { $0.contains("is offline") }, "a reconnect is not called offline")
    }

    /// The thread on screen; then its host disconnects (as after a failed try).
    static func offline(_ app: MobileApp) async {
        app.hosts.disconnect(FixtureData.studio)
        await FixtureWindows.wait("offline", seconds: 5) { app.hosts.host(FixtureData.studio)?.phase == .disconnected }
        SidebarAutomationsCheck.enableAccessibility()
        try? await Task.sleep(for: .seconds(1))
        let labels = SidebarAutomationsCheck.labels()
        check(labels.contains { $0.contains("Studio is offline") } && labels.contains("Retry connection"), "offline says so, with Retry")
    }

    /// iPad: preview, then another thread, then back and forth. Kept threads flip visibility:
    /// only the newly shown thread mounts, and only the selected one is in accessibility.
    static func switchThreads(_ app: MobileApp) async {
        guard app.navigator.layout == .pad else {
            check(true, "phone: no detail deck")
            return
        }
        let first = FixtureData.ref(FixtureData.preview)
        let second = FixtureData.ref(FixtureData.extensions)
        SHRenderProbe.start()
        for ref in [second, first, second, first] {
            app.navigator.open(.thread(ref))
            await FixtureWindows.wait("selected", seconds: 5) { app.navigator.padSelection == ref }
            try? await Task.sleep(for: .milliseconds(600))
        }
        let mounts = SHRenderProbe.stop()["thread.appear", default: 0]
        check(mounts == 1, "four switches between two threads mounted one new thread screen (\(mounts))")
        SidebarAutomationsCheck.enableAccessibility()
        try? await Task.sleep(for: .seconds(1))
        let labels = SidebarAutomationsCheck.labels()
        check(app.threads.viewers(for: second).count == 0 && app.threads.viewers(for: first).count == 1,
              "only the shown thread runs its poll (hidden \(app.threads.viewers(for: second).count), shown \(app.threads.viewers(for: first).count))")
        // The running thread (kept behind) has Stop agent in its bar; the idle one shown has none.
        check(!labels.contains("Stop agent"), "a kept thread adds nothing to the bar")
        app.navigator.open(.thread(second))
        await FixtureWindows.wait("running thread shown", seconds: 5) { app.navigator.padSelection == second }
        try? await Task.sleep(for: .seconds(1))
        check(SidebarAutomationsCheck.labels().contains("Stop agent"), "the shown running thread has its Stop agent")
        // The bar's title is the shown thread's, not a kept one's.
        let titles = SidebarAutomationsCheck.labels()
        check(titles.contains { $0.contains("Plan shepherd extensions") } && !titles.contains { $0.contains("Investigate SwiftUI live preview") },
              "the title is the shown thread's (\(titles.filter { $0.contains("shepherd extensions") || $0.contains("live preview") }))")
    }

    /// iPad, two windows: preview is kept hidden behind the running thread in the first window
    /// and shown in a second. Only the second runs it; closing that window leaves no owner behind.
    static func closeWindow(_ app: MobileApp) async {
        guard app.navigator.layout == .pad else {
            check(true, "phone: no detail deck")
            return
        }
        let preview = FixtureData.ref(FixtureData.preview)
        let running = FixtureData.ref(FixtureData.extensions)
        app.navigator.open(.thread(running))
        await FixtureWindows.wait("running shown", seconds: 5) { app.navigator.padSelection == running }
        try? await Task.sleep(for: .seconds(1))
        check(app.threads.viewers(for: preview).count == 0, "a hidden thread holds no viewer")
        await WindowsFixtures.open(preview, in: app, beside: false)
        try? await Task.sleep(for: .seconds(1))
        check(app.threads.viewers(for: preview).count == 1, "the second window alone runs it (\(app.threads.viewers(for: preview).count))")
        FixtureWindows.shared.closeOthers()
        await FixtureWindows.wait("second window closed", seconds: 6) { UIApplication.shared.openSessions.count <= 1 }
        try? await Task.sleep(for: .seconds(1))
        check(app.threads.viewers(for: preview).count == 0 && !app.threads.store(for: preview).isLive,
              "closing it leaves no viewer and the store suspended")
        // The first window runs its shown thread again once its scene is active again.
        let primary = FixtureWindows.shared.primary
        for _ in 0..<15 where app.threads.viewers(for: running).count != 1 { try? await Task.sleep(for: .milliseconds(200)) }
        check(app.threads.viewers(for: running).count == 1 || primary?.activationState != .foregroundActive,
              "the first window's shown thread runs while its scene is active (viewers \(app.threads.viewers(for: running).count), scene \(primary?.activationState.rawValue ?? -1))")
        // Back to the kept one in the first window: shown at once, running again.
        app.navigator.open(.thread(preview))
        await FixtureWindows.wait("preview shown again", seconds: 5) { app.navigator.padSelection == preview }
        try? await Task.sleep(for: .seconds(1))
        check(app.threads.viewers(for: running).count == 0, "the thread now kept hidden lets its poll go")
        check(app.threads.viewers(for: preview).count == (primary?.activationState == .foregroundActive ? 1 : 0),
              "the kept thread runs again when shown in an active scene (\(app.threads.viewers(for: preview).count))")
    }
}

/// Large reviews on the real ReviewStore. Studio (Changes engine) holds twelve Swift files of
/// 400 lines ×40 (each under the 1 MiB frame), served at revision 1 or 2 by `box`; build-01 is an
/// older host whose whole-diff reply for its agent waits on `gate`. Counts the file fetches.
@MainActor enum ReviewRetentionFixture {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var fetchCount = 0
        private var second = false
        func fetched() { lock.withLock { fetchCount += 1 } }
        var fetches: Int { lock.withLock { fetchCount } }
        var secondRevision: Bool {
            get { lock.withLock { second } }
            set { lock.withLock { second = newValue } }
        }
        let gate = DispatchSemaphore(value: 0)
        private var waiting = false
        var legacyWaiting: Bool {
            get { lock.withLock { waiting } }
            set { lock.withLock { waiting = newValue } }
        }
    }

    nonisolated(unsafe) static let box = Box()
    static let second = ChangesRevision(old: "3f2a91c0d4", new: "c0ffee0000")

    static func diffText(files: Int, lines: Int, width: Int, tag: String) -> String {
        var text = ""
        let pad = String(repeating: "x", count: width)
        for file in 0..<files {
            text += "diff --git a/Sources/Big\(file).swift b/Sources/Big\(file).swift\nnew file mode 100644\n--- /dev/null\n"
            text += "+++ b/Sources/Big\(file).swift\n@@ -0,0 +1,\(lines) @@\n"
            for line in 0..<lines { text += "+let \(tag)\(line) = compute(\"\(pad)\")\n" }
        }
        return text
    }

    static func hosts() -> [FixtureHostData] {
        let first = DiffFile.parse(diffText(files: 40, lines: 400, width: 360, tag: "rev1_"))
        let next = DiffFile.parse(diffText(files: 40, lines: 400, width: 360, tag: "rev2_"))
        func repo(_ files: [DiffFile]) -> ChangesFixture.Repo {
            ChangesFixture.Repo(files: files, branch: "big", base: "main", baseName: "main", mergeBase: "3f2a91c", lastTurn: nil, turnFiles: [])
        }
        let one = ChangesFixture.reply(repo(first)), two = ChangesFixture.reply(repo(next))
        let box = box
        let second = second
        var hosts = FixtureData.hosts()
        hosts[0].reply = { request in
            let later = box.secondRevision
            if case .agentQuery(_, _, .changesFile) = request { box.fetched() }
            guard let reply = (later ? two : one)(request) else { return nil }
            if later, case .agentResult(let id, .changesList(var list)) = reply {
                list.revision = second
                return .agentResult(id: id, result: .changesList(list))
            }
            return reply
        }
        // build-01: an older host (no Changes engine) whose whole diff is just under a frame.
        hosts[1].capabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.changesCapability }
        let legacy = (try? JSONEncoder().encode(legacyFiles)) ?? Data()
        hosts[1].reply = { request in
            guard case .agentQuery(let id, _, .review) = request else { return nil }
            box.legacyWaiting = true
            box.gate.wait()
            return .agentResult(id: id, result: .review(files: legacy, reference: nil))
        }
        return hosts
    }

    static let legacyFiles = DiffFile.parse(diffText(files: 1, lines: 7_000, width: 8, tag: "o"))
    /// What the older host's whole diff costs the review once it lands.
    static var legacyCost: Int { legacyFiles.reduce(0) { $0 + ReviewStore.cost(ChangesFileDiff(file: $1)) } }

    static func check(_ ok: Bool, _ what: String) {
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)")
        fflush(stdout)
    }

    /// Fetches, colors and draws the review's files (as its screen does) until it holds more than `floor`.
    static func fill(_ store: ReviewStore, above floor: Int = .max) async {
        for entry in store.entries {
            store.ensure(entry.id)
            await ReviewFixture.until { store.diffs[entry.id] != nil && store.texts[entry.id] != nil }
            _ = store.unifiedRows(entry.id, gaps: false)
            if store.retainedCost > floor { return }
        }
    }

    static func sources(_ store: ReviewStore) -> [String] {
        store.entries.flatMap { entry in
            store.unifiedRows(entry.id, gaps: false).compactMap { row -> String? in
                if case .line(let content) = row { return content.source } else { return nil }
            }
        }
    }

    static func run(_ app: MobileApp) async {
        let reviews = ReviewStores.shared
        let ref = FixtureData.ref(FixtureData.preview)
        let store = reviews.store(for: ref)
        reviews.appeared(ref)
        await store.load(hosts: app.hosts)
        await fill(store)
        let files = store.entries.map(\.id)
        check(files.count == 40 && store.retainedCost > 8 << 20 && store.cachedRowFiles == 40,
              "the shown review holds hunks, colored text and rows (\(store.retainedCost >> 20) MiB)")
        if let line = store.diff(files[0])?.hunks.first?.lines.first?.id {
            store.select(fileID: files[0], lineID: line)
            store.draft = "Name this better."
            store.saveDraft()
        }
        if let line = store.diff(files[1])?.hunks.first?.lines.dropFirst().first?.id {
            store.select(fileID: files[1], lineID: line)
            store.draft = "Unsent thought"
        }
        store.toggleViewed(files[2])
        store.toggleCollapsed(files[3])

        // Revision replaced: the old rows go with their hunks at once; the new revision's fill the
        // cache past its budget and push the old revision's hunks out. Every row is the new text.
        box.secondRevision = true
        await store.load(hosts: app.hosts)
        check(store.list?.revision == second && store.cachedRowFiles == 0 && store.diffs.isEmpty && store.texts.isEmpty,
              "a new revision lets go of the old rows, hunks and text at once")
        await fill(store)
        let shown = sources(store)
        check(!shown.isEmpty && shown.allSatisfy { $0.contains("rev2_") }, "every drawn row is the new revision's text")
        check(store.cachedDiffs < 80 && store.retainedCost > 0, "the old revision's cached hunks were evicted (\(store.cachedDiffs) cached)")
        check(store.comments.count == 1 && store.draft == "Unsent thought" && store.viewed == [files[2]] && store.collapsed.contains(files[3]),
              "the reviewer's marks survive the new revision")

        // Off screen over budget alone: every payload owner lets go; marks stay.
        reviews.disappeared(ref)
        check(store.diffs.isEmpty && store.texts.isEmpty && store.cachedRowFiles == 0 && store.cachedDiffs == 0 && store.retainedCost == 0,
              "off screen over budget: hunks, text, rows and cache all let go (\(store.retainedCost) bytes left)")
        check(store.comments.count == 1 && store.draft == "Unsent thought" && store.viewed == [files[2]] && store.collapsed.contains(files[3]),
              "the comment, the draft, viewed and collapsed files stay")

        // Shown again: it fetches its files, marks as they were. Then held under the budget.
        let before = box.fetches
        reviews.appeared(ref)
        await store.loadIfNeeded(hosts: app.hosts)
        // Just under the budget: the late whole diff alone tips it over.
        let floor = ReviewStores.offscreenBudget - legacyCost
        await fill(store, above: floor)
        check(box.fetches > before && store.comments.count == 1, "shown again it fetches its files and keeps its marks")
        reviews.disappeared(ref)
        let kept = store.retainedCost
        check(kept > floor && kept <= ReviewStores.offscreenBudget, "under the budget it is kept off screen (\(kept >> 20) MiB)")

        // An older host's whole diff, asked while shown and answered after its screen left: it
        // counts at once, and the older review over budget goes.
        let legacyRef = FixtureData.ref(FixtureData.buffer, on: FixtureData.buildBox)
        let legacy = reviews.store(for: legacyRef)
        reviews.appeared(legacyRef)
        let loading = Task { await legacy.load(hosts: app.hosts) }
        await FixtureWindows.wait("legacy reply held", seconds: 10) { box.legacyWaiting }
        reviews.disappeared(legacyRef)
        check(store.retainedCost == kept, "nothing goes before the reply lands")
        box.gate.signal()
        await loading.value
        check(!legacy.diffs.isEmpty && legacy.retainedCost == legacyCost,
              "the late whole diff landed (\(legacy.retainedCost >> 20) MiB)")
        check(store.retainedCost == 0 && store.diffs.isEmpty && store.cachedRowFiles == 0, "and pushed the older review out at once")
        check(store.comments.count == 1, "whose marks stay")

        // A fetch asked for, then a shed before it runs: no request, nothing kept.
        let asked = box.fetches
        let task = store.ensure(files[0])
        store.shed()
        await task?.value
        try? await Task.sleep(for: .milliseconds(300))
        check(box.fetches == asked && store.diffs.isEmpty && store.cachedDiffs == 0 && store.retainedCost == 0,
              "a fetch overtaken by a shed asks nothing and keeps nothing (\(box.fetches - asked) asked)")
        // One already asked: its reply lands after the shed and is dropped.
        reviews.appeared(ref)
        await store.loadIfNeeded(hosts: app.hosts)
        let inFlight = store.ensure(files[1])
        await Task.yield()
        store.shed()
        await inFlight?.value
        check(store.diffs.isEmpty && store.cachedDiffs == 0 && store.retainedCost == 0, "a reply after a shed is not kept")
        reviews.disappeared(ref)
    }
}

/// Exercises the real store's outer-task cancellation forwarding, not just stale publication.
@MainActor enum ReviewPreparationFixture {
    private final class Worker: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var entered = false
        private var observedCancel = false
        private var finished = false
        private var expired = false
        private var calls = 0
        var waiting: Bool { lock.withLock { entered } }
        var workerObservedCancel: Bool { lock.withLock { observedCancel } }
        var firstFinished: Bool { lock.withLock { finished } }
        var timedOut: Bool { lock.withLock { expired } }

        func release() { gate.signal() }

        func prepare(_ file: DiffFile, _ palette: ReviewTextPalette, _ words: Bool) -> [Int: AttributedString] {
            let first = lock.withLock { calls += 1; return calls == 1 }
            var checked = false
            let lines = ReviewText.prepare(file, palette: palette, words: words, isCancelled: {
                if first && !checked {
                    checked = true
                    lock.withLock { entered = true }
                    // Only a detached worker waits, with a backstop even if the fixture exits.
                    if gate.wait(timeout: .now() + 10) == .timedOut { lock.withLock { expired = true } }
                }
                if first && Task.isCancelled { lock.withLock { observedCancel = true } }
                return Task.isCancelled
            })
            if first { lock.withLock { finished = true } }
            return lines
        }
    }

    private enum Invalidation: String, CaseIterable {
        case shed, forget, whitespace, fullFiles, scope, words, replacement
    }

    private static let path = "preparation.swift"
    private static func file(_ version: Int) -> DiffFile {
        DiffFile.parse("""
        diff --git a/preparation.swift b/preparation.swift
        --- a/preparation.swift
        +++ b/preparation.swift
        @@ -1,2 +1,2 @@
        -let value = compute(1)
        -let label = "old"
        +let value = compute(\(version + 2))
        +let label = "version\(version)"
        """).first!
    }

    private static func check(_ ok: Bool, _ message: String) {
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(message)")
    }

    static func run(_ app: MobileApp) async {
        let palette = ReviewTextPalette(Color.sh)
        // Every cancellation checkpoint must discard partial output, including mid-file work.
        for words in [false, true] {
            var checks = 0
            let full = ReviewText.prepare(file(0), palette: palette, words: words, isCancelled: { checks += 1; return false })
            check(full.count == 4 && checks > 4, "normal mobile preparation keeps all four colored lines")
            var discardedEveryPartial = true
            for stop in 1...checks {
                var seen = 0
                let cancelled = ReviewText.prepare(file(0), palette: palette, words: words,
                                                   isCancelled: { seen += 1; return seen >= stop })
                discardedEveryPartial = discardedEveryPartial && cancelled.isEmpty
            }
            check(discardedEveryPartial, "mobile preparation discards partial output at all \(checks) checkpoints, words=\(words)")
        }
        for invalidation in Invalidation.allCases { await invalidate(invalidation, app: app) }
        await twoViewers(app)
        print("REVIEW PREPARATION CANCELLATION CHECK COMPLETE")
    }

    private static func invalidate(_ invalidation: Invalidation, app: MobileApp) async {
        let worker = Worker()
        defer { worker.release() } // All normal/early-return paths release the held worker.
        var requests = 0
        func makeStore() -> ReviewStore {
            ReviewStore(ref: FixtureData.ref(FixtureData.preview), prepareText: { worker.prepare($0, $1, $2) }) { _, _, query in
                switch query {
                case .changesList(let scope, _):
                    return .changesList(ChangesList(scope: scope, revision: ChangesRevision(old: "aaaa", new: "bbbb"),
                                                   comparison: ChangesComparison(head: "working", base: "HEAD"),
                                                   files: [ChangesFixture.listed(file(0))]))
                case .changesFile:
                    requests += 1
                    return .changesFile(ChangesFileDiff(file: file(requests)))
                default: throw RemoteHostClientError.rejected(code: "fixture", message: "No overview needed")
                }
            }
        }
        var store = makeStore()
        await store.load(hosts: app.hosts)
        await store.ensure(path)?.value
        await FixtureCheck.wait("\(invalidation) worker entered", seconds: 5) { worker.waiting }
        let old = store
        switch invalidation {
        case .shed:
            store.shed()
            await store.loadIfNeeded(hosts: app.hosts)
        case .forget:
            store.forget()
            store = makeStore()
            await store.load(hosts: app.hosts)
        case .whitespace: store.setIgnoreWhitespace(true)
        case .fullFiles: store.setFullFiles(true)
        case .scope: store.pick(.unstaged)
        case .words: store.setWordDiffs(false)
        case .replacement: store.loadWhole(path)
        }
        await FixtureCheck.wait("\(invalidation) replacement list", seconds: 5) { !store.loading }
        store.ensure(path)
        await FixtureCheck.wait("\(invalidation) replacement publishes before obsolete worker finishes", seconds: 5) {
            store.texts[path] != nil
        }
        worker.release()
        await FixtureCheck.wait("\(invalidation) obsolete worker completed", seconds: 5) { worker.firstFinished }
        check(!worker.timedOut && worker.workerObservedCancel, "\(invalidation): workerObservedCancel, not merely rejected publication")
        let expected = store.diff(path).map { ReviewText.prepare($0, palette: ReviewTextPalette(Color.sh), words: store.wordDiffs) }
        check(expected?.isEmpty == false && store.texts[path] == expected, "\(invalidation): replacement publishes the current file/options")
        if invalidation == .forget { check(old.texts.isEmpty && old.diffs.isEmpty, "forgotten store stays empty") }
        store.forget()
    }

    private static func twoViewers(_ app: MobileApp) async {
        let reviews = ReviewStores.shared
        let ref = FixtureData.ref(FixtureData.preview)
        let store = reviews.store(for: ref)
        reviews.appeared(ref)
        reviews.appeared(ref)
        defer { reviews.disappeared(ref) }
        await store.load(hosts: app.hosts)
        let files = Array(store.entries.prefix(2)).map(\.id) // Current file plus existing next-file prefetch.
        check(files.count == 2, "two-viewer fixture has a current and prefetched file")
        for id in files { await store.ensure(id)?.value }
        await FixtureCheck.wait("initial shared preparation", seconds: 5) { files.allSatisfy { store.texts[$0] != nil } }
        // Starts owned jobs synchronously; this actor has not yielded before one reader leaves.
        store.setWordDiffs(false)
        reviews.disappeared(ref)
        check(store.viewers == 1, "one of two readers leaving preserves the shared review")
        await FixtureCheck.wait("remaining reader and prefetch preparation", seconds: 5) {
            files.allSatisfy { store.texts[$0] != nil }
        }
        check(files.allSatisfy { id in
            guard let file = store.diff(id) else { return false }
            return store.texts[id] == ReviewText.prepare(file, palette: ReviewTextPalette(Color.sh), words: false)
        }, "one disappearing viewer cancels neither current-file nor prefetched preparation")
    }
}

/// A host that refuses sends (`busy`) or answers them `outcome_unknown`, by `mode`.
@MainActor enum RefusedSendFixture {
    final class Mode: @unchecked Sendable {
        private let lock = NSLock()
        private var unknown = false
        private var count = 0
        /// Sends the host was asked for.
        var sends: Int { lock.withLock { count } }
        func sent() { lock.withLock { count += 1 } }
        var outcomeUnknown: Bool {
            get { lock.withLock { unknown } }
            set { lock.withLock { unknown = newValue } }
        }
    }

    static let mode = Mode()

    static func hosts() -> [FixtureHostData] {
        var hosts = ThreadFixtures.hosts()
        let mode = mode
        hosts[0].accepts = { request in
            guard case .nativeThread(let id, _, .send) = request else { return nil }
            mode.sent()
            return mode.outcomeUnknown
                ? .nativeThread(id: id, result: .failure(code: "outcome_unknown", message: "The agent did not answer in time."))
                : .nativeThread(id: id, result: .failure(code: "busy", message: "The agent is busy. Try again."))
        }
        return hosts
    }

    static func check(_ ok: Bool, _ what: String) {
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)")
        fflush(stdout)
    }

    nonisolated static let recoveredIDs = (UUID(), UUID())

    /// The thread's hosts, and, for this screen only (the catalog is built for every screen), the
    /// kept sends an earlier launch saved, written before the app makes its stores.
    static func recoveredHosts() -> [FixtureHostData] {
        if ProcessInfo.processInfo.environment["FIXTURE_SCREEN"] == "composer-recovered" {
            ThreadRecovery.save([
                ThreadRecoveryRecord(id: recoveredIDs.0, typed: "Maybe it went yesterday", state: .uncertain, images: 0),
                ThreadRecoveryRecord(id: recoveredIDs.1, typed: "Rename the ledger export", state: .failed, images: 2),
            ], for: FixtureData.ref(FixtureData.preview), defaults: .standard)
        }
        return ThreadFixtures.hosts()
    }

    static func recovered(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        check(app.threads.recovered[ref]?.map(\.state) == [.uncertain, .failed], "an earlier launch's kept sends come back")
        check(app.threads.restoreRecovered(recoveredIDs.0, for: ref) == nil, "the unknown one is never restored")
        store.draft = "typing now"
        check(app.threads.restoreRecovered(recoveredIDs.1, for: ref) == nil && store.draft == "typing now", "a new draft is never replaced")
        store.draft = ""
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    static func run(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        let state = ComposerStates.shared.state(for: ref)
        let key = NativeDraftKey.text(host: ref.host, agent: ref.agent)
        await FixtureWindows.wait("ready to send", seconds: 10) { store.acceptsSend }

        // Refused: the text and image stay with the send, out of the composer, and its text is
        // what a restart keeps.
        store.draft = "Ship the ledger fix"
        await state.attach([(png(), "ledger.png")])
        await ThreadComposer.send(.followUp, store: store, state: state).value
        let refused = store.submissions.first { $0.state == .failed }
        check(refused?.typed == "Ship the ledger fix" && refused?.images.count == 1 && state.attachments.isEmpty && store.draft.isEmpty,
              "a refused send keeps its text and image, out of the composer")
        let saved = { ThreadRecovery.load(ref, defaults: .standard).records }
        await FixtureWindows.wait("refused send saved", seconds: 5) { saved().map(\.state) == [.failed] }
        check(saved().first?.typed == "Ship the ledger fix" && saved().first?.images == 1 && UserDefaults.standard.string(forKey: key) == nil,
              "its text is saved apart from the draft, without its image's bytes")

        // A newer draft and image: Restore waits, and nothing of theirs is replaced.
        store.draft = "A newer thought"
        await state.attach([(png(), "new.png")])
        check(!state.canRestore(into: store), "Restore waits while the composer holds something")
        check(store.draft == "A newer thought" && state.attachments.count == 1 && store.submissions.contains { $0.id == refused?.id },
              "the newer draft and image stay")

        // Emptied: Restore brings back the text and its image.
        store.draft = ""
        state.clearAttachments()
        if let id = refused?.id, state.canRestore(into: store), let value = store.restoreSubmission(id) {
            await state.restore(value.images)
        }
        check(store.draft == "Ship the ledger fix" && state.attachments.count == 1 && store.submissions.isEmpty,
              "restored into the empty composer with its image")

        // Unknown outcome: kept as unknown, never restorable or resent, never saved as a draft.
        mode.outcomeUnknown = true
        var sends = mode.sends
        await ThreadComposer.send(.followUp, store: store, state: state).value
        let unknown = store.submissions.first
        check(unknown?.state == .uncertain, "an outcome_unknown answer is uncertain (\(String(describing: unknown?.state)))")
        try? await Task.sleep(for: .milliseconds(1500))
        check(mode.sends == sends + 1, "an unknown outcome is never sent again by the app (\(mode.sends - sends) sends)")
        check(unknown.map { store.restoreSubmission($0.id) == nil } == true && store.submissions.count == 1, "an uncertain send cannot be restored")
        await FixtureWindows.wait("unknown send saved", seconds: 5) { saved().map(\.state) == [.uncertain] }
        check(UserDefaults.standard.string(forKey: key) == nil, "an uncertain send is saved as unknown, never as a draft")
        // Discarded: this device's copy goes; the host hears nothing.
        sends = mode.sends
        if let id = unknown?.id { check(store.canDiscardSubmission(id) && store.discardSubmission(id), "an uncertain send can be discarded") }
        check(store.submissions.isEmpty && mode.sends == sends, "discarding sends nothing")

        // The recovery limit: eight refused sends kept, the ninth refused before it leaves, its
        // draft and image untouched.
        mode.outcomeUnknown = false
        for index in 1...NativeThreadStore.maximumRetainedSubmissions {
            store.draft = "Refused \(index)"
            await ThreadComposer.send(.followUp, store: store, state: state).value
        }
        sends = mode.sends
        store.draft = "Ninth"
        await state.attach([(png(), "ninth.png")])
        await ThreadComposer.send(.followUp, store: store, state: state).value
        check(store.submissions.count == NativeThreadStore.maximumRetainedSubmissions && mode.sends == sends,
              "past the limit nothing is sent (\(store.submissions.count) kept)")
        check(store.draft == "Ninth" && state.attachments.count == 1 && (store.notice ?? "").contains("limit"),
              "and its draft and image stay, with why")
        for submission in store.submissions where store.canDiscardSubmission(submission.id) { store.discardSubmission(submission.id) }
        check(store.submissions.isEmpty, "settled sends can all be discarded")
        state.clearAttachments()

        // Leave one unknown and one refused for the shot.
        mode.outcomeUnknown = true
        store.draft = "Ship the ledger fix"
        await ThreadComposer.send(.followUp, store: store, state: state).value
        mode.outcomeUnknown = false
        store.draft = "Not this one"
        await ThreadComposer.send(.followUp, store: store, state: state).value
        check(store.submissions.map(\.state) == [.uncertain, .failed], "both shown: unknown and refused")
    }
}

/// Two real windows on one thread: the host holds the first send until `gate` is signalled, then refuses it.
@MainActor enum TwoWindowFixture {
    final class Gate: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        var sends: Int { lock.withLock { count } }
        func sent() { lock.withLock { count += 1 } }
    }

    static let gate = Gate()

    static func hosts() -> [FixtureHostData] {
        var hosts = ThreadFixtures.hosts()
        let gate = gate
        hosts[0].accepts = { request in
            guard case .nativeThread(let id, _, .send) = request else { return nil }
            gate.sent()
            // Bounded: a setup that never signals refuses after a while instead of hanging the host.
            _ = gate.semaphore.wait(timeout: .now() + 30)
            return .nativeThread(id: id, result: .failure(code: "busy", message: "The agent is busy. Try again."))
        }
        return hosts
    }

    static func check(_ ok: Bool, _ what: String) {
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)")
        fflush(stdout)
    }

    /// Sends the draft once the shared store is running, again if a scene change refused it
    /// (its draft kept), until the host holds it as send number `sends`; never once it has.
    static func sendReachingHost(store: NativeThreadStore, state: ComposerState, sends: Int) async -> Task<Void, Never> {
        let draft = store.draft
        for _ in 0..<40 {
            await FixtureWindows.wait("store running", seconds: 10) { store.isLive && store.acceptsSend }
            let attempt = ThreadComposer.send(.followUp, store: store, state: state)
            for _ in 0..<10 {
                if gate.sends >= sends { return attempt }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if gate.sends >= sends { return attempt }
            await attempt.value
            if gate.sends >= sends { return attempt }
            check(store.draft == draft, "a send refused while not running keeps the draft")
        }
        check(false, "send \(sends) never reached the host (notice: \(store.notice ?? "-"))")
        return Task {}
    }

    static func run(_ app: MobileApp, forget: Bool) async {
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        let state = ComposerStates.shared.state(for: ref)
        // A real second scene (UIKit), not the split fixture's two views in one window.
        FixtureWindows.shared.open(.thread(ref))
        await FixtureWindows.wait("second window on the thread", seconds: 15) {
            app.windows.open.filter { $0.navigator.selectedThread == ref }.count == 2
        }
        let windows = app.windows.open.filter { $0.navigator.selectedThread == ref }.count
        check(windows == 2, "two real windows show the thread (\(windows))")
        // The window in front runs the shared store (the system keeps one scene active here).
        await FixtureWindows.wait("a window runs it", seconds: 10) { app.threads.viewers(for: ref).count >= 1 && store.acceptsSend }
        let running = app.threads.viewers(for: ref).count
        check(running >= 1, "\(running) window(s) running the shared store (the simulator keeps one scene active)")

        // Window A sends; the host holds it. The text is saved before the composer clears.
        store.draft = "Sent from window A"
        // The system moves activity between the two scenes as the second opens: send once the
        // shared store is running again (a send while it isn't is refused, its draft kept).
        let send = await sendReachingHost(store: store, state: state, sends: 1)
        check(gate.sends == 1, "the send reaches the host (notice: \(store.notice ?? "-"), ready: \(store.ready), busy: \(store.busy), draft: \(store.draft))")
        let saved = ThreadRecovery.load(ref, defaults: .standard).records
        check(saved.map(\.typed) == ["Sent from window A"] && saved.first?.state == .uncertain && store.draft.isEmpty,
              "while held, its text is saved and out of the shared composer")
        // Window B types meanwhile (the composer is shared across windows).
        store.draft = "Typed in window B"
        gate.semaphore.signal()
        await send.value
        check(store.submissions.first?.state == .failed && store.draft == "Typed in window B",
              "the refusal lands without touching window B's draft")
        let refused = store.submissions[0].id
        check(store.restoreSubmission(refused) == nil && store.draft == "Typed in window B",
              "Restore from window A waits while window B's draft is there")
        store.draft = ""
        check(store.restoreSubmission(refused)?.typed == "Sent from window A" && store.draft == "Sent from window A",
              "with the composer empty, it restores")

        // Reconnect: the shared store and its saved state are the same after.
        store.draft = ""
        store.draft = "Second try"
        let second = await sendReachingHost(store: store, state: state, sends: 2)
        gate.semaphore.signal()
        await second.value
        let before = app.hosts.host(ref.host)?.session
        app.hosts.retry(ref.host)
        await FixtureWindows.wait("reconnected", seconds: 10) {
            app.hosts.host(ref.host)?.phase == .connected && app.hosts.host(ref.host)?.session != before
        }
        check(store.submissions.count == 1 && ThreadRecovery.load(ref, defaults: .standard).records.map(\.typed) == ["Second try"],
              "a reconnect keeps the refused send and its saved copy")

        guard forget else {
            check(app.windows.open.filter { $0.navigator.selectedThread == ref }.count == 2, "both windows still open for the shot")
            return
        }
        // Forget the host: every window lets the thread go and its saved sends are removed.
        try? await app.forget(host: ref.host)
        try? await Task.sleep(for: .milliseconds(500))
        check(!UserDefaults.standard.dictionaryRepresentation().keys.contains {
            $0.hasPrefix(ThreadRecovery.prefix + ref.host.uuidString) || $0.hasPrefix(ThreadRecovery.asidePrefix + ref.host.uuidString)
        } && app.threads.recovered[ref] == nil && app.hosts.host(ref.host) == nil,
              "forgetting the host removes its saved sends")
        FixtureWindows.shared.closeOthers()
    }
}

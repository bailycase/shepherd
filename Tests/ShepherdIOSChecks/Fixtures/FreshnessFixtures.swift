import Foundation
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
            FixtureScreen(name: "pad-switch", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FreshnessFixtures.switchThreads),
            // Run with -w: a thread kept hidden in one window and shown in a second, which then closes.
            FixtureScreen(name: "windows-deck-close", hosts: ThreadFixtures.hosts(), routes: [.thread(preview)],
                          prepare: FreshnessFixtures.closeWindow),
        ]
    }
}

@MainActor enum FreshnessFixtures {
    static func check(_ ok: Bool, _ what: String) { FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)") }

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

/// Large changes for the preview agent: four Swift files of 5,000 added lines each (about 9 MiB
/// of hunks before their colored text), and a count of the file fetches the host answered.
@MainActor enum ReviewRetentionFixture {
    final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    nonisolated(unsafe) static let fetches = Fetches()

    static func hosts() -> [FixtureHostData] {
        var text = ""
        let pad = String(repeating: "x", count: 380)
        for file in 0..<4 {
            text += "diff --git a/Sources/Big\(file).swift b/Sources/Big\(file).swift\nnew file mode 100644\n--- /dev/null\n"
            text += "+++ b/Sources/Big\(file).swift\n@@ -0,0 +1,5000 @@\n"
            for line in 0..<5000 { text += "+let value\(line) = compute(\"\(pad)\") // \(line)\n" }
        }
        let files = DiffFile.parse(text)
        var hosts = FixtureData.hosts()
        let changes = ChangesFixture.reply(ChangesFixture.Repo(files: files, branch: "big", base: "main", baseName: "main", mergeBase: "3f2a91c",
                                                               lastTurn: nil, turnFiles: []))
        let fetches = fetches
        hosts[0].reply = { request in
            if case .agentQuery(_, _, .changesFile) = request { fetches.add() }
            return changes(request)
        }
        return hosts
    }

    static func check(_ ok: Bool, _ what: String) { FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)") }

    static func run(_ app: MobileApp) async {
        let reviews = ReviewStores.shared
        let ref = FixtureData.ref(FixtureData.preview)
        let store = reviews.store(for: ref)
        // A screen shows it: every file fetched, colored, and drawn.
        reviews.appeared(ref)
        await store.load(hosts: app.hosts)
        await ChangesFixture.filesLoaded(store)
        for entry in store.entries { _ = store.unifiedRows(entry.id, gaps: false) }
        let files = store.entries.map(\.id)
        let held = store.retainedCost
        check(files.count == 4 && held > 8 << 20 && store.cachedRowFiles == 4 && !store.texts.isEmpty,
              "the shown review holds hunks, colored text and rows (\(held >> 20) MiB, \(store.cachedRowFiles) row sets)")
        // The reviewer's own marks.
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

        // It leaves the screen: past the off-screen budget alone, every payload owner lets go.
        reviews.disappeared(ref)
        check(store.diffs.isEmpty && store.texts.isEmpty && store.cachedRowFiles == 0 && store.cachedDiffs == 0 && store.retainedCost == 0,
              "off screen over budget: hunks, text, rows and cache all let go (\(store.retainedCost) bytes left)")
        check(store.comments.count == 1 && store.draft == "Unsent thought" && store.viewed == [files[2]] && store.collapsed.contains(files[3]),
              "the comment, the draft, viewed and collapsed files stay")

        // Shown again: it fetches what it needs, the marks as they were.
        let before = fetches.value
        reviews.appeared(ref)
        await store.loadIfNeeded(hosts: app.hosts)
        await ChangesFixture.filesLoaded(store)
        check(fetches.value == before + 4 && store.comments.count == 1 && store.draft == "Unsent thought",
              "shown again it fetches its files and keeps its marks")

        // A fetch asked for, then a shed before it runs: no request, nothing kept.
        reviews.disappeared(ref)
        let asked = fetches.value
        let task = store.ensure(files[0])
        store.shed()
        await task?.value
        try? await Task.sleep(for: .milliseconds(300))
        check(fetches.value == asked && store.diffs.isEmpty && store.cachedDiffs == 0 && store.retainedCost == 0,
              "a fetch overtaken by a shed asks nothing and keeps nothing (\(fetches.value - asked) asked)")
        // And one already asked: its reply lands after the shed and is dropped.
        reviews.appeared(ref)
        await store.loadIfNeeded(hosts: app.hosts)
        let inFlight = store.ensure(files[1])
        await Task.yield()
        store.shed()
        await inFlight?.value
        check(store.diffs.isEmpty && store.cachedDiffs == 0, "a reply after a shed is not kept")
        reviews.disappeared(ref)
    }
}

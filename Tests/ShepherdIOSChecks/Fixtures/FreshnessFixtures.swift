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
        await FixtureWindows.wait("second window closed", seconds: 10) { UIApplication.shared.openSessions.count <= 1 }
        try? await Task.sleep(for: .seconds(1))
        check(app.threads.viewers(for: preview).count == 0 && !app.threads.store(for: preview).isLive,
              "closing it leaves no viewer and the store suspended")
        // The first window runs its shown thread again once its scene is active again.
        let primary = FixtureWindows.shared.primary
        for _ in 0..<50 where app.threads.viewers(for: running).count != 1 { try? await Task.sleep(for: .milliseconds(200)) }
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

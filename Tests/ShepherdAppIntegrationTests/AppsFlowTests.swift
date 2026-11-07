import AppKit
import Darwin
import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings › Apps and the header's Run (AppsSettings, AppsAdd, AppsQuickAction, AppsRunning,
/// AppsNewThread boards) against a real server: Add app writes the space's `.shepherd/apps.json`;
/// Run starts the app in the background with no thread needed; from a thread, its output opens as
/// a read-only tab in that thread's panel, which closes without stopping the app; and quitting
/// stops every app.
@Suite("Apps", .mainActorExclusive)
@MainActor
struct AppsFlowTests {
    @Test func addAppSavesInTheSpaceAndShowsAsAQuickAction() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let root = app.dir.appendingPathComponent("payments")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)
        let space = Fixture.space("payments", path: root.path)
        let thread = Fixture.agent("Add refund events", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread]))
        vm.selectAgent(thread.agent.id)
        #expect(vm.quickApps(in: space.id) == nil, "no apps, no Run button")

        vm.apps.add(scope: .space(space.id))
        let editor = try #require(vm.apps.editor)
        #expect(editor.folders == ["", "web"])
        #expect(editor.invalid == "Name the app")
        editor.name = "Web app"
        editor.command = "npm run dev"
        editor.folder = "web"
        #expect(await editor.save())

        let saved = try AppsFile.load(AppsFile.url(in: root.path))
        #expect(saved == [AppDefinition(name: "Web app", command: "npm run dev", folder: "web", opens: .browser,
                                        address: "http://localhost:3000", quickAction: true)])
        let apps = vm.apps
        try await eventuallyOnMain("the space's apps to load") { apps.group(.space(space.id))?.apps.count == 1 }
        let quick = try #require(vm.quickApps(in: space.id))
        #expect(quick.space == "payments" && quick.items.map(\.app.name) == ["Web app"] && quick.items[0].status == nil)

        // A second app by the same name in the same place is refused, and the file kept.
        vm.apps.add(scope: .space(space.id))
        let twin = try #require(vm.apps.editor)
        twin.name = "Web app"
        twin.command = "pnpm dev"
        #expect(await twin.save() == false)
        #expect(twin.problem == "There is already an app named Web app there.")
        #expect(try AppsFile.load(AppsFile.url(in: root.path)).count == 1)
    }

    /// Run from Settings with no thread at all: it runs in the space's folder, its state reaches
    /// every view, and Stop ends it.
    @Test func anAppRunsWithNoThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("ledger", path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        let key = AppKey(scope: .space(space.id), name: "Worker")
        vm.runApp(AppDefinition(name: "Worker", command: "pwd; echo 'up on localhost:4100'; sleep 60", quickAction: true), key: key)
        let apps = vm.apps
        try await eventuallyOnMain("the app to run on its port", timeout: .seconds(20)) {
            apps.process(key)?.status == .running && apps.process(key)?.port == 4100
        }
        #expect(apps.process(key)?.directory == app.dir.path)
        vm.stopApp(key)
        try await eventuallyOnMain("the app to stop") { apps.process(key)?.status.isLive == false }
    }

    /// From a thread: the output opens on a tab in its panel (no terminal is added to the layout),
    /// and closing that tab leaves the app running.
    @Test func theOutputTabIsAViewThatClosesWithoutStoppingTheApp() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("payments", path: app.dir.path)
        let thread = Fixture.agent("Add refund events", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread]))
        vm.selectAgent(thread.agent.id)
        let key = AppKey(scope: .space(space.id), name: "Worker")
        vm.runApp(AppDefinition(name: "Worker", command: "echo worker-up; sleep 60"), key: key, showOutput: true)
        let apps = vm.apps, panels = vm.terminalPanels
        let panel = TerminalPanelKey(host: nil, tab: thread.tab.id)
        try await eventuallyOnMain("the output tab", timeout: .seconds(20)) { panels.appTabs[panel]?.count == 1 }
        #expect(vm.state.tabs.first { $0.id == thread.tab.id }?.layout.leaves.count == 1, "no terminal joins the layout")
        #expect(panels.panel(panel).shown)
        try await eventuallyOnMain("its output", timeout: .seconds(20)) { apps.process(key)?.lineCount == 1 }
        #expect(await vm.server.apps.lines(key, tail: 5) == ["worker-up"])

        let target = try #require(vm.terminalTarget)
        let tab = try #require(panels.appTabs[panel]?.first)
        vm.closeTerminalTab(tab, target: target)
        #expect(panels.appTabs[panel] == nil && !panels.panel(panel).shown)
        #expect(apps.process(key)?.status.isLive == true, "closing the view leaves the app running")
        vm.stopApp(key)
        try await eventuallyOnMain("the app to stop") { apps.process(key)?.status.isLive == false }
    }

    @Test func quittingStopsEveryApp() async throws {
        let app = try AppHarness()
        let space = Fixture.space("payments", path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        let key = AppKey(scope: .mac, name: "Postgres")
        // This Mac's apps run from home.
        try FileManager.default.createDirectory(atPath: vm.apps.home, withIntermediateDirectories: true)
        vm.runApp(AppDefinition(name: "Postgres", command: "sleep 300 & echo \"child $!\"; wait"), key: key)
        var child: pid_t?
        try await eventuallyAsync("the child's pid", timeout: .seconds(20)) {
            child = await vm.server.apps.lines(key, tail: 5).lazy.compactMap { $0.hasPrefix("child ") ? pid_t($0.dropFirst(6)) : nil }.first
            return child != nil
        }
        let pid = try #require(child)
        #expect(kill(pid, 0) == 0)
        app.stop()
        #expect(kill(pid, 0) != 0, "quitting ended the app's whole group")
    }

    /// The Run and Stop the boards draw, pressed as VoiceOver would: the header's, Settings' and
    /// New thread's each start and stop the app.
    @Test func theDrawnRunAndStopButtonsRunAndStopTheApp() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressRunAndStop() }
        }
    }

    private static func pressRunAndStop() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("payments", path: app.dir.path)
        try AppsFile.save([AppDefinition(name: "Worker", command: "sleep 60", quickAction: true)], to: AppsFile.url(in: app.dir.path))
        let thread = Fixture.agent("Add refund events", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread]))
        vm.selectAgent(thread.agent.id)
        let apps = vm.apps
        apps.reload()
        try await eventuallyOnMain("the space's apps") { apps.group(.space(space.id))?.apps.count == 1 }
        let key = AppKey(scope: .space(space.id), name: "Worker")
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        // Settings on its own: behind it, the window's thread header offers the same Run.
        let settings = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, SettingsView(vm: vm))
        defer { settings.close() }

        func runThenStop(_ place: String, in window: OffscreenWindow) async throws {
            window.layout()
            try ControlPress.press("Run Worker", under: window.host)
            try await eventuallyOnMain("\(place)'s Run to run the app", timeout: .seconds(20)) { apps.process(key)?.status.isLive == true }
            try await eventuallyOnMain("\(place)'s Stop to show") {
                window.layout()
                return ControlPress.controls(in: window.host).contains { $0.label == "Stop Worker" }
            }
            try ControlPress.press("Stop Worker", under: window.host)
            try await eventuallyOnMain("\(place)'s Stop to stop it") { apps.process(key)?.status.isLive == false }
            // It exited: Restart (the header's button says Run again), then Stop again.
            var again = ""
            try await eventuallyOnMain("\(place)'s Restart to show") {
                window.layout()
                again = ControlPress.controls(in: window.host).compactMap(\.label).first { $0 == "Restart Worker" || $0 == "Run Worker" } ?? ""
                return !again.isEmpty
            }
            try ControlPress.press(again, under: window.host)
            try await eventuallyOnMain("\(place)'s Restart to run it", timeout: .seconds(20)) { apps.process(key)?.status.isLive == true }
            vm.stopApp(key)
            try await eventuallyOnMain("it to stop") { apps.process(key)?.status.isLive == false }
            vm.server.apps.forget(key)
            try await eventuallyOnMain("it to be forgotten") { apps.process(key) == nil }
        }
        vm.settingsSection = .apps
        try await runThenStop("Settings", in: settings)
        try ControlPress.press("Add app to payments", under: settings.host)
        #expect(apps.editor?.scope == .space(space.id) && apps.editor?.original == nil)
        apps.editor = nil
        vm.openNewThread()
        try await runThenStop("New thread", in: window)
        vm.selectAgent(thread.agent.id)
        try await runThenStop("the header", in: window)
    }
}

/// The agent's app tools over the real extension socket (`ExtensionMessage.app`): an agent lists
/// its own space's apps, runs one it is allowed to, reads its output and stops it; it is refused
/// an app whose "Agents can start it" is off, and an app of another space.
@Suite("App tools", .mainActorExclusive)
@MainActor
struct AppToolsFlowTests {
    @Test func anAgentRunsReadsAndStopsItsSpacesAppAndIsRefusedTheRest() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let payments = app.dir.appendingPathComponent("payments"), ledger = app.dir.appendingPathComponent("ledger")
        try AppsFile.save([AppDefinition(name: "Worker", command: "echo worker-up; sleep 60", agents: true),
                           AppDefinition(name: "Docs", command: "sleep 60")], to: AppsFile.url(in: payments.path))
        try AppsFile.save([AppDefinition(name: "Ledger job", command: "sleep 60", agents: true)], to: AppsFile.url(in: ledger.path))
        let space = Fixture.space("payments", path: payments.path), other = Fixture.space("ledger", path: ledger.path)
        let thread = Fixture.agent("Add refund events", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space, other], agents: [thread]))
        let agent = thread.agent.id

        func text(_ reply: ExtensionReply) -> String? { if case .appResult(_, let text) = reply { text } else { nil } }
        func code(_ reply: ExtensionReply) -> String? { if case .error(_, let code, _) = reply { code } else { nil } }

        let list = try #require(text(try await app.extensionRequest(.app(id: 1, agentID: agent, action: .list, name: nil, lines: nil))))
        #expect(list.contains("- Worker: not running · you can run it"))
        #expect(list.contains("- Docs: not running · only the user can run it"))
        #expect(!list.contains("Ledger job"), "another space's apps are not listed")

        let started = try #require(text(try await app.extensionRequest(.app(id: 2, agentID: agent, action: .run, name: "Worker", lines: nil))))
        #expect(started.hasPrefix("Started Worker"))
        let key = AppKey(scope: .space(space.id), name: "Worker")
        let apps = vm.apps
        try await eventuallyOnMain("Settings and the header to see it run", timeout: .seconds(20)) { apps.process(key)?.lineCount == 1 }
        let logs = try #require(text(try await app.extensionRequest(.app(id: 3, agentID: agent, action: .logs, name: "Worker", lines: 5))))
        #expect(logs.hasSuffix("\nworker-up"), "\(logs)")

        #expect(code(try await app.extensionRequest(.app(id: 4, agentID: agent, action: .run, name: "Docs", lines: nil))) == "not_allowed")
        #expect(code(try await app.extensionRequest(.app(id: 5, agentID: agent, action: .run, name: "Ledger job", lines: nil))) == "no_such_app")
        #expect(code(try await app.extensionRequest(.app(id: 6, agentID: agent, action: .logs, name: "Ledger job", lines: nil))) == "no_such_app")
        // Logs need no switch: any app of the space.
        #expect(text(try await app.extensionRequest(.app(id: 7, agentID: agent, action: .logs, name: "Docs", lines: nil))) == "Docs hasn't run since Shepherd started.")

        let stopped = try #require(text(try await app.extensionRequest(.app(id: 8, agentID: agent, action: .stop, name: "Worker", lines: nil))))
        #expect(stopped.hasPrefix("Stopping Worker"))
        try await eventuallyOnMain("the app to stop") { apps.process(key)?.status.isLive == false }
    }
}

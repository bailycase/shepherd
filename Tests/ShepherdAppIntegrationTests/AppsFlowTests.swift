import AppKit
import Foundation
import SwiftUI
import ShepherdCore
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings › Apps and the header's Run (AppsSettings, AppsAdd, AppsQuickAction, AppsRunning
/// boards) against a real server: Add app writes the space's `.shepherd/apps.json`, Run opens a
/// terminal tab named for the app under the thread and runs the command even with the thread off
/// screen, and Stop closes that tab.
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
        #expect(quick.space == "payments" && quick.items.map(\.app.name) == ["Web app"] && quick.items[0].unavailable == nil)

        // A second app by the same name in the same place is refused, and the file kept.
        vm.apps.add(scope: .space(space.id))
        let twin = try #require(vm.apps.editor)
        twin.name = "Web app"
        twin.command = "pnpm dev"
        #expect(await twin.save() == false)
        #expect(twin.problem == "There is already an app named Web app there.")
        #expect(try AppsFile.load(AppsFile.url(in: root.path)).count == 1)
    }

    @Test func runOpensANamedTerminalUnderTheThreadAndStopClosesIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("payments", path: app.dir.path)
        let thread = Fixture.agent("Add refund events", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread]))
        vm.selectAgent(thread.agent.id)
        let definition = AppDefinition(name: "Worker", command: "printf 'worker-%s\\n' up", quickAction: true)
        let key = AppKey(scope: .space(space.id), name: "Worker")

        // No view draws the thread's terminals here: Run starts the shell itself.
        vm.runApp(definition, key: key)
        let apps = vm.apps
        try await eventuallyOnMain("the app to be running", timeout: .seconds(20)) { apps.run(key) != nil }
        let run = try #require(apps.run(key))
        #expect(run.agentID == thread.agent.id)
        let tab = try #require(vm.state.tabs.first { $0.id == thread.tab.id })
        let leaf = try #require(tab.layout.leaf(withID: run.paneID))
        #expect(leaf.title == "Worker" && leaf.agentID == nil && leaf.cwd == app.dir.path)
        #expect(TerminalPanel.tabs(in: tab.layout, thread: thread.piPane.id).map(\.id) == [run.paneID])

        let server = app.server
        var session: SessionID?
        try await eventuallyAsync("the command's output", timeout: .seconds(20)) {
            session = await MainActor.run { vm.state.tabs.first { $0.id == thread.tab.id }?.layout.leaf(withID: run.paneID)?.sessionID }
            guard let session else { return false }
            return await server.screenText(sessionID: session)?.contains { $0.contains("worker-up") } == true
        }

        vm.runApp(definition, key: key)
        #expect(vm.state.tabs.first { $0.id == thread.tab.id }?.layout.leaves.count == 2, "Run on a running app opens nothing more")

        vm.stopApp(key)
        #expect(apps.run(key) == nil)
        #expect(vm.state.tabs.first { $0.id == thread.tab.id }?.layout.leaf(withID: run.paneID) == nil)
        let stopped = try #require(session)
        try await eventuallyAsync("the app's shell to end") { await server.sessionInfo(sessionID: stopped)?.isAlive != true }
    }

    @Test func closingTheTabByHandEndsTheRun() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("payments", path: app.dir.path)
        let thread = Fixture.agent("Add refund events", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread]))
        vm.selectAgent(thread.agent.id)
        let key = AppKey(scope: .mac, name: "Postgres")
        vm.runApp(AppDefinition(name: "Postgres", command: "true"), key: key)
        let apps = vm.apps
        try await eventuallyOnMain("the app to be running", timeout: .seconds(20)) { apps.run(key) != nil }
        let run = try #require(apps.run(key))
        #expect(vm.state.tabs.first { $0.id == thread.tab.id }?.layout.leaf(withID: run.paneID)?.cwd == apps.home,
                "This Mac's app runs from home")
        #expect(vm.closeLocalPane(run.paneID))
        #expect(apps.run(key) == nil)
    }

    @Test func aSpaceWithNoThreadCannotRunItsApps() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let empty = Fixture.space("ledger", path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [empty], agents: []))
        #expect(vm.appThread(for: .space(empty.id)) == nil)
        #expect(vm.appRunUnavailable(.space(empty.id)) == "Start a thread in ledger to run its apps")
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
            try await eventuallyOnMain("\(place)'s Run to run the app", timeout: .seconds(20)) { apps.run(key) != nil }
            try await eventuallyOnMain("\(place)'s Stop to show") {
                window.layout()
                return ControlPress.controls(in: window.host).contains { $0.label == "Stop Worker" }
            }
            try ControlPress.press("Stop Worker", under: window.host)
            #expect(apps.run(key) == nil, "\(place)'s Stop")
        }
        try await runThenStop("the header", in: window)
        vm.settingsSection = .apps
        try await runThenStop("Settings", in: settings)
        try ControlPress.press("Add app to payments", under: settings.host)
        #expect(apps.editor?.scope == .space(space.id) && apps.editor?.original == nil)
        apps.editor = nil
        vm.openNewThread()
        try await runThenStop("New thread", in: window)
    }
}

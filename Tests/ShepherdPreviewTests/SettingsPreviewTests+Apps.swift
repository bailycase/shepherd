import AppKit
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Apps (AppsSettings, AppsAdd, AppsQuickAction, AppsRunning, AppsNewThread boards) in light and
/// dark, from apps files written in a scratch space and home and read through the real model;
/// running apps are real terminals under the thread.
extension SettingsPreviewTests {
    @MainActor private struct AppsFixture {
        let workspace: PreviewWorkspace
        let space: Space
        let agent: Agent
        var vm: ShepherdViewModel { workspace.vm }

        init() async throws {
            _ = NSApplication.shared
            workspace = try PreviewWorkspace()
            let root = workspace.dir.appendingPathComponent("payments")
            let fm = FileManager.default
            for folder in ["web", "worker", "ios"] {
                try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            // Its package.json serves two scripts that aren't apps yet.
            try Data(#"{"name":"payments","scripts":{"dev":"next dev","start":"node server.js","preview":"vite preview"}}"#.utf8)
                .write(to: root.appendingPathComponent("package.json"))
            try AppsFile.save([
                AppDefinition(name: "Web app", command: "npm run dev", opens: .browser, address: "http://localhost:3000", quickAction: true),
                AppDefinition(name: "Storybook", command: "npm run storybook", folder: "web", opens: .browser,
                              address: "http://localhost:6006", quickAction: true),
                AppDefinition(name: "iOS app", command: "xcodebuild -scheme Payments && xcrun simctl launch booted com.acme.pay",
                              folder: "ios", opens: .window, quickAction: true),
                AppDefinition(name: "Refund worker", command: "go run ./cmd/worker", folder: "worker"),
            ], to: AppsFile.url(in: root.path))
            try AppsFile.save([AppDefinition(name: "Postgres", command: "postgres -D ~/pg/data")],
                              to: AppsFile.url(in: workspace.vm.apps.home))
            space = Space(name: "payments", path: root.path)
            let (agent, tab) = try await workspace.agent("Add refund events", in: space, order: 0, live: true)
            self.agent = agent
            try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
            workspace.vm.selectAgent(agent.id)
            let apps = workspace.vm.apps
            apps.reload()
            try await eventuallyOnMain("the apps to load") { apps.group(.space(space.id))?.apps.count == 4 }
        }

        /// Runs `name` for real, with a stand-in command that stays up.
        func run(_ name: String, scope: AppScope) async throws {
            let key = AppKey(scope: scope, name: name)
            let app = try #require(vm.apps.apps(in: space.id).first { $0.key == key }?.app)
            var standIn = app
            // The shell's own prompt names this machine: clear it away so the terminal shows only
            // the app's command, as the board does.
            standIn.command = "clear; printf '$ %s\\n' '\(app.command)'; sleep 120"
            vm.runApp(standIn, key: key)
            let apps = vm.apps, vm = vm, server = workspace.server
            try await eventuallyOnMain("\(name) to run", timeout: .seconds(20)) { apps.run(key) != nil }
            let pane = try #require(apps.run(key)).paneID
            var screen: [String] = []
            try await eventuallyAsync("\(name)'s terminal to show only its command", timeout: .seconds(20)) {
                guard let session = await MainActor.run(body: { vm.state.tabs.lazy.compactMap { $0.layout.leaf(withID: pane) }.first?.sessionID })
                else { return false }
                screen = (await server.screenText(sessionID: session) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return screen == ["$ \(app.command)"]
            }
            #expect(!screen.joined().contains(ProcessInfo.processInfo.hostName.components(separatedBy: ".")[0]))
        }
    }

    @Test func settingsApps() async throws {
        let fixture = try await AppsFixture()
        defer { fixture.workspace.stop() }
        try await fixture.run("Postgres", scope: .mac)
        try await fixture.run("Web app", scope: .space(fixture.space.id))
        fixture.vm.settingsSection = .apps
        try await Preview.render("settings-apps", size: CGSize(width: 1440, height: 900)) { SettingsView(vm: fixture.vm) }

        // Add app, as the board fills it in.
        fixture.vm.apps.add(scope: .space(fixture.space.id))
        let editor = try #require(fixture.vm.apps.editor)
        editor.name = "Web app"
        editor.command = "npm run dev"
        editor.folder = "web"
        try await Preview.render("settings-apps-add", size: CGSize(width: AppLayout.appsSheetWidth, height: AppLayout.appsSheetHeight)) {
            AppEditSheet(editor: editor) {}
        }
        editor.opens = .terminal
        try await Preview.render("settings-apps-add-terminal", size: CGSize(width: AppLayout.appsSheetWidth, height: AppLayout.appsSheetHeight)) {
            AppEditSheet(editor: editor) {}
        }
    }

    /// The thread header's Run button at rest (AppsQuickAction), then with Web app running: its
    /// output in the terminal panel and the Browser waiting for its address (AppsRunning).
    @Test func threadHeaderApps() async throws {
        let fixture = try await AppsFixture()
        defer { fixture.workspace.stop() }
        let store = fixture.vm.threadStores.store(for: fixture.agent.id)
        try await Preview.render("apps-quick-action", size: CGSize(width: 1440, height: 900), ready: { store.ready }) {
            RootView(vm: fixture.vm)
        }
        try await fixture.run("Web app", scope: .space(fixture.space.id))
        let run = try #require(fixture.vm.apps.run(AppKey(scope: .space(fixture.space.id), name: "Web app")))
        let tab = try #require(fixture.vm.state.tabs.first { $0.layout.leaf(withID: run.paneID) != nil })
        let terminal = fixture.vm.sessions.session(for: try #require(tab.layout.leaf(withID: run.paneID)), in: tab)
        try await Preview.render("apps-running", size: CGSize(width: 1600, height: 900), ready: { store.ready && terminal.phase == .live }) {
            RootView(vm: fixture.vm)
        }
    }

    @Test func newThreadApps() async throws {
        let fixture = try await AppsFixture()
        defer { fixture.workspace.stop() }
        fixture.vm.openNewThread()
        try await Preview.render("apps-new-thread", size: CGSize(width: 1440, height: 900), ready: { fixture.vm.newThread.place != nil }) {
            RootView(vm: fixture.vm)
        }
    }
}

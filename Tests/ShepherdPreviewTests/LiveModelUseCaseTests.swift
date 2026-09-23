import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Opt-in live use case against a real model through the user's own pi configuration: the real
/// view model and SessionServer and a real `pi --mode rpc`, rendered in a window far off-screen
/// that never takes focus, driven through view-model calls (no synthetic input). A cheap model
/// is plenty:
///
///     SHEPHERD_LIVE_MODEL=cpa/~anthropic/claude-haiku-latest SHEPHERD_PREVIEW_DIR=/tmp/live \
///         swift test --filter LiveModelUseCaseTests
///
/// Costs a few model turns. With SHEPHERD_PREVIEW_DIR set it also writes
/// `live-<step>-<light|dark>.png`. Shepherd's support directory is a scratch one; pi's session
/// files for the scratch checkout are removed afterwards. Run it on its own (`--filter`): the
/// fixture previews and the app tests put a stub `pi` first on PATH for the rest of the process,
/// so while SHEPHERD_LIVE_MODEL is set the fixture previews stay off.
@Suite("Live model use cases", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_LIVE_MODEL"]?.isEmpty == false, "set SHEPHERD_LIVE_MODEL to run"))
@MainActor
struct LiveModelUseCaseTests {
    @Test func anAgentEditsAFileTheUserReviewsItAndTheAgentAddressesTheReview() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = try #require(env["SHEPHERD_LIVE_MODEL"])
        let shots = Preview.directory
        let fm = FileManager.default
        let root = try makeScratchDirectory("live")
        let cwd = root.appendingPathComponent("calc")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try "def add(a, b):\n    return a + b\n".write(to: cwd.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["config", "user.name", "Shepherd Live"], ["config", "user.email", "live@example.com"],
                     ["add", "."], ["commit", "-qm", "init"]] {
            try git(args, in: cwd)
        }

        // The support directory is the test process's scratch one (ShepherdTestKit).
        let server = SessionServer(socketPath: ShepherdPaths.socketURL().path, stateURL: ShepherdPaths.stateURL())
        try server.start()
        let sessionsDir = PiSessionFile.projectDirectory(forCwd: cwd.path)
        let defaultsName = "shepherd.live.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            server.stop()
            try? fm.removeItem(at: sessionsDir)
            try? fm.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let settings = AppSettings(store: defaults)
        settings.worktreeGeneratePRDescription = false
        let vm = ShepherdViewModel(server: server, settings: settings, keybindings: KeybindingsStore(store: defaults),
                                   themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in })
        let space = Space(name: "calc", path: cwd.path)
        try await server.addSpace(space)
        try await eventuallyOnMain("the space to load") { vm.state.spaces.count == 1 }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1500, height: 940),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(vm: vm))
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func shot(_ name: String) throws {
            guard let shots else { return }
            try fm.createDirectory(at: shots, withIntermediateDirectories: true)
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: shots.appendingPathComponent("live-\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        // 1. A new agent edits a file and answers. Started in the background: selecting it
        //    afterwards never activates the app or makes the window key.
        let agentID = try await vm.startAgent(NewAgentConfig(
            spaceID: space.id, workingDirectory: cwd.path, model: model, thinking: .off,
            initialPrompt: "Add a subtract(a, b) function to calc.py using the edit tool. Then reply with one short sentence."),
            selectAfter: false)
        vm.selectAgent(agentID)
        let store = vm.threadStores.store(for: agentID)
        try await eventuallyOnMain("the first turn to finish", timeout: .seconds(240)) {
            !store.settledRunning && store.messages.contains { $0.role == "assistant" } && store.messages.contains { $0.toolName == "edit" }
        }
        #expect(try String(contentsOf: cwd.appendingPathComponent("calc.py"), encoding: .utf8).contains("def subtract"))
        try shot("1-thread")

        // 2. The edit's "review ›" link opens the review pane at the file.
        vm.openReview(agentID: agentID, path: "calc.py")
        let review = try #require(vm.reviewSessions.values.first { $0.agentID == agentID })
        try await eventuallyOnMain("the diff to load", timeout: .seconds(20)) { !review.isLoading && !review.files.isEmpty }
        #expect(review.files.map(\.displayPath) == ["calc.py"])
        try shot("2-review")

        // 3. Request changes: an inline comment and an overall note go to the agent as its next turn.
        let file = try #require(review.files.first)
        let line = try #require(file.hunks.flatMap(\.lines).first { $0.kind == .added })
        review.comments = [ReviewComment(fileID: file.id, lineID: line.id, filePath: file.displayPath,
                                         lineNumber: line.newLine ?? 0, marker: "+", content: line.text,
                                         text: "Add a one-line docstring here.")]
        review.summary = "Looks good otherwise."
        let before = store.messages.count { $0.role == "user" }
        vm.submitReview(review)
        try await eventuallyOnMain("the review to close", timeout: .seconds(20)) { vm.reviewSessions.isEmpty }
        try await eventuallyOnMain("the agent to address the review", timeout: .seconds(240)) {
            store.messages.count { $0.role == "user" } > before && !store.settledRunning && store.messages.last?.role == "assistant"
        }
        try shot("3-after-review")

        // 4. The palette over the thread, and a Settings page.
        vm.showCommandPalette = true
        try shot("4-palette")
        vm.showCommandPalette = false
        vm.showSettings = true
        vm.settingsSection = .agents
        try shot("5-settings")
        vm.showSettings = false

        // 5. Deleting the agent retires its process and its thread.
        vm.deleteAgent(agentID)
        try await eventuallyOnMain("the agent to go", timeout: .seconds(20)) { vm.state.agents.isEmpty && server.state.agents.isEmpty }
        try shot("6-empty")
    }
}

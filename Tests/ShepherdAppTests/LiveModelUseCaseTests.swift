import AppKit
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
@testable import ShepherdApp

/// Opt-in live use cases against a real model through the user's own pi configuration: the
/// real view model and SessionServer, a real `pi --mode rpc`, rendered in a window that sits
/// far off-screen and never takes focus. Driven through view-model calls, not synthetic input.
///
///     SHEPHERD_LIVE_MODEL=anthropic/claude-sonnet-4-6 SHEPHERD_NATIVE_SCREENSHOT_DIR=/tmp/live \
///         swift test --filter LiveModelUseCaseTests
///
/// Costs a few cheap model turns. Shepherd's support directory is a scratch one; pi's session
/// files for the scratch checkout are removed afterwards.
@Suite("Live model use cases", .serialized)
@MainActor
struct LiveModelUseCaseTests {
    @Test func agentEditsReviewsAndRespondsToAReview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["SHEPHERD_LIVE_MODEL"], !model.isEmpty else { return }
        let shots = env["SHEPHERD_NATIVE_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/slive-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        let support = root.appendingPathComponent("s"), cwd = root.appendingPathComponent("calc")
        for dir in [support, cwd] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try "def add(a, b):\n    return a + b\n".write(to: cwd.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["config", "user.name", "Shepherd Live"], ["config", "user.email", "live@example.com"],
                     ["add", "."], ["commit", "-qm", "init"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = args
            git.currentDirectoryURL = cwd
            try git.run(); git.waitUntilExit()
        }

        let savedSupport = env[ShepherdPaths.supportDirectoryEnvKey]
        setenv(ShepherdPaths.supportDirectoryEnvKey, support.path, 1)
        let server = SessionServer(socketPath: ShepherdPaths.socketURL().path, stateURL: ShepherdPaths.stateURL())
        try server.start()
        let sessionsDir = PiSessionFile.projectDirectory(forCwd: cwd.path)
        defer {
            server.stop()
            if let savedSupport { setenv(ShepherdPaths.supportDirectoryEnvKey, savedSupport, 1) } else { unsetenv(ShepherdPaths.supportDirectoryEnvKey) }
            try? fm.removeItem(at: sessionsDir)
            try? fm.removeItem(at: root)
        }

        let defaults = UserDefaults(suiteName: "shepherd.live.\(UUID().uuidString)")!
        let vm = ShepherdViewModel(server: server, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in })
        let space = Space(name: "calc", path: cwd.path)
        try await server.addSpace(space)
        try await waitFor("space") { vm.state.spaces.count == 1 }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1500, height: 940),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RootView(vm: vm))
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func shot(_ name: String, dark: Bool = true) async throws {
            guard let shots else { return }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(0.8)
            try fm.createDirectory(at: shots, withIntermediateDirectories: true)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: shots.appendingPathComponent("live-\(name)-\(dark ? "dark" : "light").png"))
        }

        // 1. A new agent edits a file and answers.
        let agentID = try await vm.startAgent(NewAgentConfig(
            spaceID: space.id, workingDirectory: cwd.path, model: model, thinking: .off,
            initialPrompt: "Add a subtract(a, b) function to calc.py using the edit tool. Then reply with one short sentence."))
        let store = vm.threadStores.store(for: agentID)
        // Diagnostics for a stuck run: what the server itself holds for this agent.
        func dump() async {
            let result = try? await server.nativeThread(agentID: agentID, request: .snapshot())
            print("LIVE-DIAG store messages=\(store.messages.count) running=\(store.snapshot?.running as Any) notice=\(store.notice ?? "-")")
            if case .snapshot(let snap)? = result {
                print("LIVE-DIAG server running=\(snap.running) model=\(snap.model ?? "-") messages=\(snap.messages.count)")
                for m in snap.messages.suffix(8) { print("LIVE-DIAG msg \(m.role) \(m.toolName ?? "") \(m.status ?? "") \(m.blocks.map(\.text).joined().prefix(160))") }
            } else { print("LIVE-DIAG server result=\(String(describing: result))") }
            print("LIVE-DIAG agent status=\(server.state.agents.first?.status.rawValue ?? "-")")
        }
        let firstTurnDone = { !store.settledRunning && store.messages.contains { $0.role == "assistant" } && store.messages.contains { $0.toolName == "edit" } }
        let deadline = ContinuousClock.now + .seconds(240)
        while !firstTurnDone(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(500)) }
        if !firstTurnDone() { await dump() }
        try #require(firstTurnDone(), "timed out waiting for the first turn to finish")
        let calc = try String(contentsOf: cwd.appendingPathComponent("calc.py"), encoding: .utf8)
        #expect(calc.contains("def subtract"))
        try await shot("1-thread")
        try await shot("1-thread", dark: false)

        // 2. The edit's "review ›" link opens the review pane at the file.
        vm.openReview(agentID: agentID, path: "calc.py")
        let review = try #require(vm.reviewSessions.values.first { $0.agentID == agentID })
        try await waitFor("the diff") { !review.isLoading && !review.files.isEmpty }
        #expect(review.files.map(\.displayPath) == ["calc.py"])
        try await shot("2-review")

        // 3. Request changes: an inline comment and an overall note go to the agent as its next turn.
        let file = try #require(review.files.first)
        let line = try #require(file.hunks.flatMap(\.lines).first { $0.kind == .added })
        review.comments = [ReviewComment(fileID: file.id, lineID: line.id, filePath: file.displayPath,
                                         lineNumber: line.newLine ?? 0, marker: "+", content: line.text,
                                         text: "Add a one-line docstring here.")]
        review.summary = "Looks good otherwise."
        let before = store.messages.count { $0.role == "user" }
        vm.submitReview(review)
        try await waitFor("the review to close") { vm.reviewSessions.isEmpty }
        try await waitFor("the agent to address the review", timeout: .seconds(240)) {
            store.messages.count { $0.role == "user" } > before && !store.settledRunning
                && store.messages.last?.role == "assistant"
        }
        try await shot("3-after-review")

        // 4. The palette over the thread, and the Settings page.
        vm.showCommandPalette = true
        try await shot("4-palette")
        vm.showCommandPalette = false
        vm.showSettings = true
        vm.settingsSection = .agents
        try await shot("5-settings")
        vm.showSettings = false

        // 5. Deleting the agent retires its process and its thread.
        vm.deleteAgent(agentID)
        try await waitFor("the agent to go") { vm.state.agents.isEmpty && server.state.agents.isEmpty }
        try await shot("6-empty")
    }

    private func settle(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private func waitFor(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(200)) }
        try #require(condition(), "timed out waiting for \(what)")
    }
}

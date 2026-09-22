import AppKit
import SwiftUI
import Testing
import Vision
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
@testable import ShepherdApp

/// Opt-in live end-to-end check of the native RPC UI: the real view model, SessionServer,
/// `pi --mode rpc`, and bundled children extension, against a scripted local provider
/// (Tests/Extensions/e2e-provider.mjs, no network). Controls are found by their visible text
/// (Vision OCR on the rendered window) and clicked with real mouse events, so a button that
/// is hidden, clipped, or not hit-testable fails the run. Every stage is screenshotted.
///
///     SHEPHERD_E2E=1 SHEPHERD_NATIVE_SCREENSHOT_DIR=/tmp/e2e swift test --filter LiveEndToEndTests
///
/// Everything lives in a scratch directory with its own PI_CODING_AGENT_DIR, so the user's pi
/// configuration, sessions, and running Shepherd are never touched.
@Suite("Live end-to-end native UI", .serialized)
@MainActor
struct LiveEndToEndTests {
    @Test func subagentLifecycleThroughTheRealUI() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SHEPHERD_E2E"] == "1" else { return }
        let shots = env["SHEPHERD_NATIVE_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let root = URL(fileURLWithPath: "/tmp/se2e-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        let fm = FileManager.default
        let agentDir = root.appendingPathComponent("pi"), support = root.appendingPathComponent("s"), cwd = root.appendingPathComponent("repo")
        for dir in [agentDir, support, cwd] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try "# Scratch repo\n".write(to: cwd.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // Scripted provider.
        let providerScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/e2e-provider.mjs").path
        let provider = Process()
        provider.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        provider.arguments = ["node", providerScript]
        let out = Pipe(), input = Pipe()
        provider.standardOutput = out; provider.standardInput = input
        provider.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try provider.run()
        let portLine = try #require(String(data: out.fileHandleForReading.availableData, encoding: .utf8))
        let port = try #require(portLine.split(separator: ":").last.flatMap { Int($0.filter(\.isNumber)) })
        try """
        {"providers":{"e2e":{"baseUrl":"http://127.0.0.1:\(port)/v1","api":"openai-completions","apiKey":"local-e2e-not-secret",
          "models":[{"id":"e2e-model","name":"e2e-model","reasoning":false,"input":["text"],"contextWindow":200000,"maxTokens":4096,
                     "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}]}}}
        """.write(to: agentDir.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: agentDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let saved = ["PI_CODING_AGENT_DIR", "PI_OFFLINE", ShepherdPaths.supportDirectoryEnvKey].map { ($0, env[$0]) }
        setenv("PI_CODING_AGENT_DIR", agentDir.path, 1); setenv("PI_OFFLINE", "1", 1)
        setenv(ShepherdPaths.supportDirectoryEnvKey, support.path, 1)
        let server = SessionServer(socketPath: ShepherdPaths.socketURL().path, stateURL: ShepherdPaths.stateURL())
        try server.start()
        let sessionsDir = PiSessionFile.projectDirectory(forCwd: cwd.path)
        defer {
            server.stop()
            try? input.fileHandleForWriting.close(); provider.terminate()
            for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? fm.removeItem(at: sessionsDir)
            try? fm.removeItem(at: root)
        }

        let defaults = UserDefaults(suiteName: "shepherd.e2e.\(UUID().uuidString)")!
        let vm = ShepherdViewModel(server: server, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in })
        let space = Space(name: "Shepherd", path: cwd.path)
        try await server.addSpace(space)
        try await waitFor("space") { vm.state.spaces.count == 1 }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1500, height: 940), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RootView(vm: vm).preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func shot(_ name: String) throws {
            guard let shots else { return }
            try fm.createDirectory(at: shots, withIntermediateDirectories: true)
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: shots.appendingPathComponent("e2e-\(name).png"))
        }

        // 1. A new RPC agent spawns three native children from its opening prompt.
        let agentID = try await vm.startAgent(NewAgentConfig(
            spaceID: space.id, workingDirectory: cwd.path, model: "e2e/e2e-model", thinking: .off,
            initialPrompt: "E2E_START Restyle the native UI to the spec. Split it up if that's faster.",
            initialName: "Restyle native UI"))
        let store = vm.threadStores.store(for: agentID)
        func run(_ role: String) -> ChildRun? { store.subagents.first { $0.role == role } }
        try await waitFor("three children, reviewer asking", timeout: .seconds(90)) {
            store.subagents.count == 3 && run("reviewer")?.needsAttention == true && run("worker")?.isTerminal == false
        }
        try await settle()
        try shot("1-live-cards")

        // 2. Inspect the running worker from its card.
        try await click("Inspect", in: host)
        try await waitFor("worker inspector") { vm.subagentInspector.runByAgent[agentID] == run("worker")?.runID }
        try await settle(1.5)
        try shot("2-live-inspector")

        // 3. Pause at the next model request, then continue.
        try await click("Pause", in: host)
        try await waitFor("worker paused") { run("worker")?.paused == true }
        try await settle()
        try shot("3-paused")
        try await click("Continue", in: host)
        try await waitFor("worker continued") { run("worker")?.paused != true }

        // 4. Answer the reviewer's question from its card.
        try await click("Replace everywhere", in: host)
        try await waitFor("reviewer answered and finished", timeout: .seconds(60)) { run("reviewer")?.state == "complete" }

        // 5. Everyone finishes: the cards fold into the ledger.
        vm.subagentInspector.runByAgent.removeValue(forKey: agentID)
        try await waitFor("all children finished", timeout: .seconds(90)) { store.subagents.count == 3 && store.subagents.allSatisfy { $0.state == "complete" } }
        try await waitFor("parent settled", timeout: .seconds(60)) { !store.settledRunning }
        try await settle(1.5)
        try shot("4-ledger")

        // 6. A finished row opens the read-only inspector.
        try await click("reviewer", in: host, below: "subagents")
        try await waitFor("reviewer inspector") { vm.subagentInspector.runByAgent[agentID] == run("reviewer")?.runID }
        try await settle(1.5)
        try shot("5-done-inspector")

        // 7. A follow-up from the composer echoes immediately and gets a reply.
        vm.subagentInspector.runByAgent.removeValue(forKey: agentID)
        try await click("Follow up", in: host)
        store.draft = "E2E_FOLLOWUP how did it go?"
        try await settle(0.3)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.window!.windowNumber,
                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        host.window!.sendEvent(key)
        try await waitFor("follow-up reply", timeout: .seconds(60)) {
            store.messages.contains { $0.blocks.contains { $0.text.contains("All three reported") } } && !store.settledRunning
        }
        try await settle()
        try shot("6-followup")
    }

    // MARK: Helpers

    private func settle(_ seconds: Double = 0.8) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private func waitFor(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try #require(condition(), "timed out waiting for \(what)")
    }

    /// Find `text` on screen with Vision OCR and click its centre with real mouse events, as a
    /// user would. `below` picks the first match under another visible string (e.g. a ledger
    /// row under its "3 subagents" header). Fails with everything OCR saw when not found.
    private func click(_ text: String, in host: NSView, below anchor: String? = nil) async throws {
        var seen: [(String, CGRect)] = []
        for _ in 0..<10 {
            seen = try recognize(host)
            let anchorY = anchor.flatMap { a in seen.first { $0.0.localizedCaseInsensitiveContains(a) }?.1.maxY }
            if let hit = seen.first(where: { item in item.0.localizedCaseInsensitiveContains(text) && (anchorY.map { item.1.minY > $0 } ?? true) }) {
                let point = CGPoint(x: hit.1.midX, y: hit.1.midY)
                let window = try #require(host.window)
                let inWindow = host.convert(NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y), to: nil)
                let hitView = window.contentView?.hitTest(window.contentView!.convert(inWindow, from: nil))
                print("E2E click '\(text)' ocr=\(hit.0) at \(point) window=\(inWindow) flipped=\(host.isFlipped) hit=\(hitView.map { String(describing: type(of: $0)) } ?? "nil")")
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                    try await Task.sleep(for: .milliseconds(40))
                }
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        Issue.record("'\(text)' not visible; OCR saw: \(seen.map(\.0).joined(separator: " | "))")
        throw CancellationError()
    }

    /// Text boxes in the host view's top-left coordinate space.
    private func recognize(_ host: NSView) throws -> [(String, CGRect)] {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = host.bounds.size
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return (candidate.string, CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                             width: box.width * size.width, height: box.height * size.height))
        }
    }
}

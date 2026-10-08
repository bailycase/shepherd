import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
import Vision
@testable import ShepherdApp

/// Drive normal snapshots without forcing a layout or screenshot between streaming updates.
/// Completion must paint the answer itself, not just have a nonzero pixel count or a visible
/// scroll marker. Captures contain generated fixtures only, never a user's session. Waits let
/// SwiftUI settle without the existing deck's forced-layout polling.
@Suite("Completed thread reproduction", .serialized, .mainActorExclusive)
@MainActor
struct ThreadCompletionReproductionTests {
    typealias Flow = ThreadTailFlowTests
    typealias Fx = ThreadBlankScreenTests

    @Test(arguments: [false, true])
    func completionPaintsTheFinalAnswerWithoutForcedStreamingLayouts(native: Bool) async throws {
        let host = Flow.FlowHost(turns: 80, mix: .moderate)
        let deck = Flow.Deck(host: host, size: CGSize(width: 2000, height: 870), native: native)
        deck.model.tray = true
        defer { deck.close() }
        try await deck.open()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-completion-repro")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for turn in 0..<8 {
            let at = Fx.base + Double(60_000 + turn * 3) * 60_000
            var workers = (0..<2).map { index in
                ChildRun(runID: "repro-\(turn)-\(index)", label: "Read-only review of project settings and thread rendering", state: "running", startedAt: at + Double(index), role: "worker")
            }
            var live = [Fx.user("repro-user-\(turn)", "Review this project using two workers.", at: at)]
            let steps = turn.isMultiple(of: 2) ? 31 : 12
            for step in 0..<steps {
                live.append(Fx.reply("repro-prose-\(turn)-\(step)", Fx.prose(step.isMultiple(of: 7) ? 40 : 1, step), at: at + Double(step) * 2000))
                live.append(Fx.tool("repro-tool-\(turn)-\(step)", "shepherd_child_wait", ["ids": workers.map(\.runID)], output: "Waiting for the review.", at: at + Double(step) * 2000))
                host.running = true
                host.provisional = live + [Fx.streamingReply(step.isMultiple(of: 3) ? 30 : 2)]
                host.subagents = workers
                host.bump()
                await deck.store.refresh()
                try await Task.sleep(for: .milliseconds(18))
            }
            for index in workers.indices {
                workers[index].state = "complete"
                workers[index].endedAt = at + 100_000
                workers[index].summary = "Review complete. No material regression found."
            }
            let answer = "The worker has finished this review."
            live.append(Fx.reply("repro-final-\(turn)", answer, at: at + 110_000))
            // Exercise both completion orders: the workers before the parent's agent_end and
            // in the same snapshot as the saved history that replaces the live page.
            if turn.isMultiple(of: 2) {
                host.subagents = workers
                host.provisional = live
                host.bump()
                await deck.store.refresh()
                try await Task.sleep(for: .milliseconds(18))
            }
            host.running = false
            host.provisional = []
            host.subagents = workers
            host.all += live
            host.bump()
            await deck.store.refresh()
            let prefix = "\(native ? "anchored" : "scrolling")-\(turn)"
            var recognizedFinal = false
            do {
                // Recovery walks the lazy stack in multiple steps. Wait on compositor pixels,
                // not a fixed delay or forced layouts that could repair the view for the test.
                try await eventuallyOnMain("\(prefix) to paint its final answer", poll: .milliseconds(100)) {
                    let image = try ThreadWindowCapture.image(deck.window.window)
                    recognizedFinal = try recognizedText(image).contains { $0.contains("worker has finished") }
                    return recognizedFinal
                }
            } catch is WaitTimeout { }
            _ = try capture(deck, to: directory.appendingPathComponent(prefix + ".png"))
            print("COMPLETION \(prefix): rows=\(deck.store.rows.count), targets=\(deck.tailGuard.visible), following=\(deck.tailGuard.following), attempts=\(deck.tailGuard.attempts), repairing=\(deck.tailGuard.repairing), rowsInView=\(deck.tailGuard.rowsInView), \(deck.reading.map(String.init(describing:)) ?? "no scroll view"), answer=\(recognizedFinal)")
            guard recognizedFinal else {
                // Save what the user would try next as evidence, not as a way to pass the test.
                deck.scroll(by: -500)
                try await Task.sleep(for: .seconds(1))
                _ = try capture(deck, to: directory.appendingPathComponent(prefix + "-scrolled.png"))
                deck.hide()
                try await Task.sleep(for: .milliseconds(100))
                deck.show()
                try await Task.sleep(for: .seconds(1))
                _ = try capture(deck, to: directory.appendingPathComponent(prefix + "-reshown.png"))
                Issue.record("Completion did not paint its final answer; see \(directory.path)/\(prefix).png")
                return
            }
        }
    }

    @Test(arguments: [CGSize(width: 900, height: 600), CGSize(width: 2000, height: 870), CGSize(width: 3200, height: 1400)])
    func realWorkspaceCompletionKeepsPainting(size: CGSize) async throws {
        let app = try AppHarness(pi: PiSetup(
            engine: PiEngine(command: [TestProcess.piEngine.path], packageDirectory: nil, version: nil, node: .onPath("node")),
            home: PiSetup.app.home))
        defer { app.stop() }
        let seed = app.dir.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: RealThreadRig.history(turns: 80, mix: .moderate)).write(to: seed)
        let (vm, window, agents) = try await MountedWorkspace.open(2, in: app, size: size, env: { $0 == 0 ? ["STUB_PI_MESSAGES_FILE": seed.path] : [:] })
        defer { window.close() }
        let agentID = agents[0].agent.id
        let store = vm.threadStores.store(for: agentID)
        let children = try ExtensionClient(path: app.scratch.socketPath)
        try children.send(.helloChildren(agentID: agentID))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-completion-repro")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for turn in 0..<18 {
            let prompt = "tools:1 completion trial \(turn)" + (turn.isMultiple(of: 2) ? " long:100" : "")
            if turn == 6 || turn == 12 {
                window.window.contentView?.setFrameSize(CGSize(width: size.width, height: 420))
                try await Task.sleep(for: .milliseconds(120))
                window.window.contentView?.setFrameSize(size)
            }
            try children.send(.setAgentStatus(agentID: agentID, status: .working))
            await store.send(text: prompt)
            try await eventuallyOnMain("pi starts its tool") { store.running }
            var workers = (0..<(turn % 8 == 7 ? 20 : 2)).map(ThreadHeavySnapshotTests.finishedRun)
            for index in workers.indices {
                workers[index].runID = "round-\(turn)-\(index)"
                workers[index].state = "running"
                workers[index].startedAt = store.lastPromptAt ?? Date().timeIntervalSince1970 * 1000
                workers[index].endedAt = nil
            }
            try children.send(.setAgentChildren(agentID: agentID, children: workers))
            try await eventuallyOnMain("worker progress") { store.subagents.contains { $0.state == "running" } }
            if turn % 4 == 2 { try children.send(.setAgentStatus(agentID: agentID, status: .done)) }
            if turn % 3 == 2 { vm.selectAgent(agents[1].agent.id) }
            for index in workers.indices {
                workers[index].state = "complete"
                workers[index].endedAt = Date().timeIntervalSince1970 * 1000
            }
            try children.send(.setAgentChildren(agentID: agentID, children: workers))
            FileManager.default.createFile(atPath: app.dir.appendingPathComponent("tool-\(turn + 1)").path, contents: nil)
            let server = app.server
            try await eventuallyAsync("pi settles and persisted history arrives", timeout: .seconds(30)) {
                if case .snapshot(let value)? = try? await server.nativeThread(agentID: agentID, request: .snapshot()) {
                    return !value.running && value.provisional.isEmpty && value.messages.contains { $0.blocks.contains { $0.text.hasPrefix("Reply to " + prompt) } }
                }
                return false
            }
            try children.send(.setAgentStatus(agentID: agentID, status: .done))
            if turn % 3 == 2 { vm.selectAgent(agentID) }
            try await eventuallyOnMain("the completed host snapshot reaches the thread") {
                !store.running && store.messages.contains { $0.blocks.contains { $0.text.hasPrefix("Reply to " + prompt) } }
            }
            let prefix = "workspace-\(Int(size.width))-\(turn)"
            var lastImage: CGImage?
            var painted = false
            do {
                // Store completion precedes painting; observe pixels without forcing layout.
                try await eventuallyOnMain("\(prefix) to paint its completed answer", poll: .milliseconds(100)) {
                    let image = try ThreadWindowCapture.image(window.window)
                    lastImage = image
                    painted = try recognizedText(image).contains {
                        let letters = $0.lowercased().filter { $0.isLetter || $0.isNumber }
                        return letters.contains("completiontrial") || letters.contains("letval") || letters.contains("paragraph")
                    }
                    return painted
                }
            } catch is WaitTimeout { }
            let bitmap = NSBitmapImageRep(cgImage: try #require(lastImage))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(prefix + ".png"))
            print("WORKSPACE \(prefix): rows=\(store.rows.count), messages=\(store.messages.count), running=\(store.running), ready=\(store.ready), children=\(store.subagents.count), mountedTabs=\(vm.mountedTabs.count), painted=\(painted)")
            guard painted else {
                Issue.record("The real workspace did not paint its completed answer; see \(directory.path)/\(prefix).png")
                return
            }
        }
        withExtendedLifetime(children) {}
    }

    @Test(arguments: [CGSize(width: 900, height: 600), CGSize(width: 2000, height: 870)])
    func openingALargeFinishedThreadPaintsItsHistory(size: CGSize) async throws {
        let host = Flow.FlowHost(turns: 80, mix: .giant)
        let deck = Flow.Deck(host: host, size: size, native: false)
        defer { deck.close() }
        deck.model.tray = true
        try await eventuallyOnMain("history loaded") { deck.store.ready && !deck.store.rows.isEmpty }
        try await Task.sleep(for: .seconds(2))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-completion-repro")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try capture(deck, to: directory.appendingPathComponent("giant-\(Int(size.width)).png"))
        let text = try recognizedText(image)
        print("GIANT", Int(size.width), deck.store.rows.count, text.suffix(10))
        #expect(text.contains { $0.contains("Paragraph") || $0.contains("value") || $0.contains("Key point") })
    }

    private func capture(_ deck: Flow.Deck, to path: URL) throws -> CGImage {
        let bitmap = NSBitmapImageRep(cgImage: try ThreadWindowCapture.image(deck.window.window))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
        return try #require(bitmap.cgImage)
    }

    private func recognizedText(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision2
        try request.useCPUForTests()
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}

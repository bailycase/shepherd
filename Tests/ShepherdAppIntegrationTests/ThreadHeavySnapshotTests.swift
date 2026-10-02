import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// A long, edit-heavy thread whose finished subagent cards weigh as much as a snapshot may,
/// drawn by the real workspace over a real server and the stub pi. Its history used to get what
/// the cards left of the snapshot: nothing, once its newest reply was bigger than that. The
/// thread showed no turns at all with the composer beside it, from the moment a turn finished until
/// something else changed what the cards or the newest message weighed (a send and a Stop).
@Suite("Thread beside heavy subagent cards", .serialized, .mainActorExclusive)
@MainActor
struct ThreadHeavySnapshotTests {
    static let base = 1_733_000_000_000.0

    /// pi's own message JSON for `pairs` question and answer pairs, the answers `bytes` long.
    static func history(pairs: Int, bytes: Int) -> Data {
        let out: [[String: Any]] = (0..<pairs).flatMap { i -> [[String: Any]] in
            [["role": "user", "content": "Question \(i)", "timestamp": base + Double(i) * 10_000],
             ["role": "assistant", "stopReason": "stop", "timestamp": base + Double(i) * 10_000 + 5000,
              "content": [["type": "text", "text": "Answer \(i). " + String(repeating: "a", count: bytes)]]]]
        }
        return try! JSONSerialization.data(withJSONObject: out)
    }

    /// A finished card that names the thirty-two files it edited, by long paths.
    static func finishedRun(_ i: Int) -> ChildRun {
        let worktree = "/Users/someone/Developer/Project/.claude/worktrees/agent-a17a1eed02e8595ae"
        var run = ChildRun(runID: "run-\(i)", label: "worker: do part \(i)", state: "complete", startedAt: 1_790_000_000_000 + Double(i),
                           endedAt: 1_790_000_100_000 + Double(i), role: "worker", turns: 40, toolCalls: 120, tokens: 400_000,
                           task: String(repeating: "t", count: 600), cwd: worktree)
        run.result = ChildResultSummary(files: 32, added: 1200, removed: 300, tools: 120, tokens: 400_000)
        run.output = String(repeating: "o", count: 600)
        run.summary = String(repeating: "s", count: 240)
        run.files = (0..<32).map { ChildFileChange(path: "\(worktree)/Sources/ShepherdApp/Thread/Module\($0)/Feature\(i)/\(String(repeating: "Long", count: 40))Thing\($0).swift", added: 20, removed: 5) }
        return run
    }

    /// Pixels in the thread's area (above the composer) that differ from its background.
    static func ink(_ window: OffscreenWindow) -> Int {
        let scroll = HiddenAgentsWorkspace.shownScrollViews(in: window).filter { $0.frame.height > 200 }
            .min { window.host.convert($0.bounds, from: $0).minX < window.host.convert($1.bounds, from: $1).minX }
        guard let scroll else { return -1 }
        var region = scroll.convert(scroll.bounds, to: window.host)
        region.size.height = max(1, region.height - scroll.contentInsets.bottom - 24)
        let capture = FrameTimer.capture(window, region)
        return capture.data.withUnsafeBytes { raw -> Int in
            let p = raw.bindMemory(to: UInt8.self)
            let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
            var count = 0
            for y in 0..<capture.height {
                let row = y * capture.bytesPerRow
                for x in 0..<capture.width {
                    let i = row + x * 4
                    if abs(Int(p[i]) - r) > 12 || abs(Int(p[i + 1]) - g) > 12 || abs(Int(p[i + 2]) - b) > 12 { count += 1 }
                }
            }
            return count
        }
    }

    @Test func aTurnThatFinishesWhileAnotherThreadIsShownLeavesItsHistoryOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let seed = app.dir.appendingPathComponent("history.json")
        try Self.history(pairs: 40, bytes: 3000).write(to: seed)
        let (vm, window, agents) = try await MountedWorkspace.open(2, in: app, env: { $0 == 0 ? ["STUB_PI_MESSAGES_FILE": seed.path] : [:] })
        defer { window.close() }
        let a = agents[0].agent.id, b = agents[1].agent.id
        let store = vm.threadStores.store(for: a)
        try await eventuallyOnMain("the history to load", timeout: .seconds(30)) { store.ready && store.rows.count > 6 }

        // The subagent cards weigh as much as a snapshot may.
        let children = try ExtensionClient(path: app.scratch.socketPath)
        try children.send(.helloChildren(agentID: a))
        let cards = (0..<20).map(Self.finishedRun)
        let weight = try JSONEncoder().encode(cards).count
        #expect(weight > 235_000, "the cards alone weigh \(weight) bytes of the snapshot's 245,760")
        try children.send(.setAgentChildren(agentID: a, children: cards))
        try await eventuallyOnMain("the cards to reach the thread") { store.subagents.count > 0 }

        // A turn that ends in the biggest reply a message gets, while the user looks at another thread.
        await store.send(text: "tools:1 the last turn long:150")
        try await eventuallyOnMain("the turn to start", timeout: .seconds(30)) { store.running }
        vm.selectAgent(b)
        ListPerf.settle(window)
        FileManager.default.createFile(atPath: app.dir.appendingPathComponent("tool-1").path, contents: nil)
        let server = app.server
        try await eventuallyAsync("the host to finish the turn", timeout: .seconds(30)) {
            if case .snapshot(let value)? = try? await server.nativeThread(agentID: a, request: .snapshot()) {
                return !value.running
            }
            return false
        }

        vm.selectAgent(a)
        func newest(_ store: NativeThreadStore) -> Bool {
            store.rows.last?.turn.messages.last?.blocks.contains { $0.text.hasPrefix("Reply to tools:1 the last turn") } == true
        }
        do {
            try await eventuallyOnMain("the thread to draw its newest reply", timeout: .seconds(10)) {
                ListPerf.settle(window)
                return newest(store) && Self.ink(window) > 0
            }
        } catch {
            Issue.record("the thread shows \(store.rows.count) turns, the newest of them not the reply (\(error))")
        }
        #expect(store.rows.count >= 8, "\(store.rows.count) turns on screen")
        withExtendedLifetime(children) {}
    }
}

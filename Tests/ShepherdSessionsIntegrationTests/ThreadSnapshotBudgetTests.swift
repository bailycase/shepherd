import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A long, edit-heavy thread, served by a real server over the stub pi: its recorded turns and its
/// finished subagent cards grow past what a snapshot may weigh, and its newest messages still
/// reach the client (docs/native-thread.md › Snapshots). They once did not: the history got what
/// the other lists left of 240 KiB, and with the newest reply bigger than that, it got nothing.
@Suite("Thread snapshot of a long, edit-heavy thread", .integrationTimeLimit)
struct ThreadSnapshotBudgetTests {
    static let worktree = "/Users/someone/Developer/Project/.claude/worktrees/agent-a17a1eed02e8595ae"

    /// pi's own message JSON for `pairs` question and answer pairs, each answer `bytes` long.
    static func history(pairs: Int, bytes: Int) -> Data {
        let base = 1_733_000_000_000.0
        let out: [[String: Any]] = (0..<pairs).flatMap { i -> [[String: Any]] in
            [["role": "user", "content": "Question \(i)", "timestamp": base + Double(i) * 10_000],
             ["role": "assistant", "stopReason": "stop", "timestamp": base + Double(i) * 10_000 + 5000,
              "content": [["type": "text", "text": "Answer \(i). " + String(repeating: "a", count: bytes)]]]]
        }
        return try! JSONSerialization.data(withJSONObject: out)
    }

    static func finishedRun(_ i: Int) -> ChildRun {
        var run = ChildRun(runID: "run-\(i)", label: "worker: " + String(repeating: "do part ", count: 12), state: "complete",
                           startedAt: 1_790_000_000_000 + Double(i), endedAt: 1_790_000_100_000 + Double(i),
                           asyncDir: "/Users/someone/Library/Application Support/Shepherd/children/run-\(i)", role: "worker",
                           model: "anthropic/claude-sonnet-5-5", turns: 40, toolCalls: 120, tokens: 400_000,
                           toolCallID: "call-\(i)", task: String(repeating: "t", count: 600),
                           sessionFile: "\(worktree)/.pi/sessions/run-\(i).jsonl", cwd: worktree)
        run.result = ChildResultSummary(files: 32, added: 1200, removed: 300, tools: 120, tokens: 400_000)
        run.output = String(repeating: "o", count: 600)
        run.summary = String(repeating: "s", count: 240)
        run.files = (0..<32).map { ChildFileChange(path: "\(worktree)/Sources/ShepherdApp/Thread/Module\($0)/Feature\(i)/\(String(repeating: "Long", count: 15))Thing\($0).swift", added: 20, removed: 5) }
        return run
    }

    @Test func aThreadWhoseCardsAndTurnsFillTheSnapshotStillShowsItsNewestMessages() async throws {
        let repo = try ChangesRepo()
        // The stub's gates appear in its cwd; they are not the agent's work.
        try "tool-*\nsettle\ncontinue-*\nhistory.json\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let seed = repo.url.appendingPathComponent("history.json")
        try Self.history(pairs: 40, bytes: 3000).write(to: seed)
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host, env: ["STUB_PI_MESSAGES_FILE": seed.path], cwd: repo.url)
        var idle = try await pi.ready()
        let changes = host.server.changes

        // Ten recorded turns, each of twenty-five long-named files, the last ending in the biggest
        // reply a message gets.
        for turn in 0..<11 {
            let last = turn == 10
            #expect(try await pi.send("tools:1 turn \(turn)\(last ? " the last long:150" : "")", from: idle).failureCode == nil)
            try await eventually("turn \(turn)'s baseline") { changes.turnStore.latest(pi.agent.id)?.startTree != nil }
            for file in 0..<25 {
                try repo.write("Sources/ShepherdApp/Thread/Module\(file)/Feature\(turn)/\(String(repeating: "Long", count: 8))Thing\(file).swift", "turn \(turn)\n")
            }
            FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-\(turn + 1)").path, contents: nil)
            try await eventually("turn \(turn) to end") {
                let latest = changes.turns(agentID: pi.agent.id).last
                return latest?.state == .ready && latest?.prompt?.hasPrefix("tools:1 turn \(turn)") == true
            }
            idle = try await pi.snapshot("the agent to settle") { !$0.running && $0.messages.last?.blocks.contains { $0.text.hasPrefix("Reply to tools:1 turn \(turn)") } == true }
        }

        // Twenty finished cards, each naming the thirty-two files it edited.
        let children = try ExtensionClient(path: host.socketPath)
        try children.send(.helloChildren(agentID: pi.agent.id))
        let cards = (0..<20).map(Self.finishedRun)
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: cards))
        let weight = RPCThreadState.bytes(NativeThreadSnapshot(
            piSessionID: "", generation: "", revision: 0, running: false, supportedActions: [], dialogsSupported: true, dialogs: [],
            messages: [], provisional: [], clipped: false, subagents: cards, turnChanges: changes.turns(agentID: pi.agent.id)))
        #expect(weight > RPCThreadState.snapshotLimit - 16 * 1024, "the cards and turns alone weigh \(weight) of \(RPCThreadState.snapshotLimit)")

        let snapshot = try await pi.snapshot("the cards in the thread") { $0.subagents?.isEmpty == false }
        #expect(snapshot.messages.count >= 20, "\(snapshot.messages.count) messages of its history")
        #expect(snapshot.messages.last?.blocks.contains { $0.text.hasPrefix("Reply to tools:1 turn 10 the last") } == true, "the newest reply")
        #expect(snapshot.olderCursor == snapshot.messages.first?.entryID, "the older ones are a page away")
        #expect(snapshot.turnChanges?.last?.files.count == ChangesLimits.turnFiles, "the newest turn keeps its files")
        #expect((snapshot.subagents ?? []).count <= cards.count)
        #expect(try JSONEncoder().encode(snapshot).count < 2 * RPCThreadState.snapshotLimit)

        // Stopping changes nothing a reader sees of the history.
        let older = try await pi.request(.snapshot(beforeEntryID: snapshot.olderCursor)).snapshotValue
        #expect(older?.messages.isEmpty == false, "the page behind the first")
    }
}

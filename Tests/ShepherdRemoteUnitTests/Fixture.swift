import Foundation
import ShepherdProtocol

/// Small builders for thread messages and child runs.
enum Fixture {
    static func tool(
        _ name: String, args: String? = nil, output: String = "", error: Bool = false,
        status: String = "complete", id: String = UUID().uuidString, callID: String? = nil,
        startedAt: Double? = nil, timestamp: Double? = nil
    ) -> NativeThreadMessage {
        NativeThreadMessage(
            entryID: id, role: "toolResult",
            blocks: output.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: output)],
            toolName: name, toolCallID: callID, argumentsText: args, status: status, isError: error,
            timestamp: timestamp, startedAt: startedAt
        )
    }

    static func user(_ text: String = "go", id: String = UUID().uuidString) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: text.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: text)])
    }

    static func assistant(_ text: String, thinking: String? = nil, status: String? = nil, id: String = UUID().uuidString) -> NativeThreadMessage {
        var blocks: [NativeThreadBlock] = []
        if let thinking { blocks.append(NativeThreadBlock(kind: .thinking, text: thinking)) }
        if !text.isEmpty { blocks.append(NativeThreadBlock(kind: .text, text: text)) }
        return NativeThreadMessage(entryID: id, role: "assistant", blocks: blocks, status: status)
    }

    static func message(_ role: String, _ text: String, id: String = UUID().uuidString) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [NativeThreadBlock(kind: .text, text: text)])
    }

    static func run(
        _ id: String, state: String = "running", startedAt: Double? = nil, endedAt: Double? = nil,
        needsAttention: Bool = false, tokens: Int? = nil, toolCallID: String? = nil
    ) -> ChildRun {
        ChildRun(runID: id, label: id, state: state, startedAt: startedAt, endedAt: endedAt,
                 needsAttention: needsAttention, tokens: tokens, toolCallID: toolCallID)
    }

    static func snapshot(
        session: String = "s", generation: String = "g", revision: UInt64 = 1, running: Bool = false,
        actions: [String] = ["send", "abort", "answer", "setModel", "setThinking", "subagents"],
        messages: [NativeThreadMessage] = [], provisional: [NativeThreadMessage] = [],
        dialogs: [NativeThreadDialog] = [], olderCursor: String? = nil, model: String? = nil,
        subagents: [ChildRun]? = nil
    ) -> NativeThreadSnapshot {
        NativeThreadSnapshot(
            piSessionID: session, generation: generation, revision: revision, running: running, model: model,
            supportedActions: actions, dialogsSupported: true, dialogs: dialogs, messages: messages,
            olderCursor: olderCursor, provisional: provisional, clipped: false, runtime: "rpc", subagents: subagents
        )
    }
}

/// The canvas's Subagent card states board (SubagentCards), timed so durations read
/// as drawn.
enum Board {
    static let now = Date(timeIntervalSince1970: 10_000)
    static var nowMS: Double { now.timeIntervalSince1970 * 1000 }

    static var worker: ChildRun {
        ChildRun(runID: "native-worker", label: "worker: restyle", state: "running", startedAt: nowMS - (37 * 60 + 21) * 1000,
                 role: "worker", turns: 78, toolCalls: 82, tokens: 922_000,
                 lastActivity: ChildActivity(tool: "edit", preview: "A.swift", diff: ChildDiff(added: 31, removed: 0), at: nowMS - 4000),
                 toolCallID: "spawn-worker")
    }
    static var reviewer: ChildRun {
        ChildRun(runID: "native-reviewer", label: "reviewer: check", state: "running", startedAt: nowMS - (2 * 60 + 10) * 1000,
                 needsAttention: true, attentionText: "Two token names collide", role: "reviewer", turns: 3, tokens: 40_000,
                 question: ChildQuestion(text: "Rename or replace?", options: ["Replace everywhere", "Rename new ones"]),
                 toolCallID: "spawn-reviewer")
    }
    static var tests: ChildRun {
        ChildRun(runID: "native-tests", label: "tests: run", state: "complete", startedAt: nowMS - 600_000,
                 endedAt: nowMS - 600_000 + (4 * 60 + 2) * 1000, role: "tests", turns: 9, toolCalls: 19, tokens: 118_000,
                 result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000), toolCallID: "spawn-tests")
    }
    static var docs: ChildRun {
        ChildRun(runID: "native-docs", label: "docs: write", state: "failed", startedAt: nowMS - 900_000, endedAt: nowMS - 100_000,
                 role: "docs", turns: 41, exitReason: "exit 1 · context limit reached after 41 turns", toolCallID: "spawn-docs")
    }
    static var cards: [ChildRun] { [worker, reviewer, tests, docs] }

    /// A finished group: worker / reviewer / tests, 45m wall.
    static var done: [ChildRun] {
        let t0 = nowMS - 45 * 60_000
        return [
            ChildRun(runID: "native-worker", label: "worker", state: "complete", startedAt: t0, endedAt: t0 + 41 * 60_000,
                     role: "worker", toolCalls: 118, tokens: 922_000,
                     result: ChildResultSummary(files: 5, added: 200, removed: 60, tools: 118, tokens: 922_000), toolCallID: "spawn-worker",
                     output: "ignored when a summary exists",
                     files: ["a", "b", "c", "d", "shared"].map { ChildFileChange(path: $0, added: 1, removed: 0) },
                     summary: "Restyled desktop thread, sidebar, composer and iOS to the spec; system fonts at spec sizes throughout. Nothing else touched."),
            ChildRun(runID: "native-reviewer", label: "reviewer", state: "complete", startedAt: t0 + 60_000, endedAt: t0 + 13 * 60_000,
                     role: "reviewer", toolCalls: 24, tokens: 460_000,
                     result: ChildResultSummary(files: 0, added: 0, removed: 0, tools: 24, tokens: 460_000), toolCallID: "spawn-reviewer",
                     output: "Two token collisions fixed. Everything else matches."),
            ChildRun(runID: "native-tests", label: "tests", state: "complete", startedAt: t0 + 41 * 60_000, endedAt: t0 + 45 * 60_000 + 2000,
                     role: "tests", toolCalls: 19, tokens: 118_000,
                     result: ChildResultSummary(files: 2, added: 118, removed: 4, tools: 19, tokens: 118_000), toolCallID: "spawn-tests",
                     files: [ChildFileChange(path: "shared", added: 96, removed: 3), ChildFileChange(path: "e", added: 22, removed: 1)],
                     summary: "Added 6 tests."),
        ]
    }
}

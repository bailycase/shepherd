import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The host's estimate of what fills pi's context (the split and the largest items), how a
/// compaction lands in the thread, and pi's compaction settings as the host reads them.
@Suite("Context estimate")
struct ContextEstimateTests {
    private static func text(_ count: Int) -> String { String(repeating: "x", count: count) }

    /// pi 0.87's structured system prompt: sections (a null removes one), the project context
    /// with its instruction files, and the tools. Four characters a token.
    private static let system = RPCMessage(
        role: "system", content: [], timestamp: 1,
        sections: ["preamble": text(400), "docs": text(400),
                   "project_context": "<project_context>\n<project_instructions path=\"/repo/AGENTS.md\">\n\(text(800))\n</project_instructions>\n"
                       + "<project_instructions path=\"/repo/Sources/CLAUDE.md\">\nmore\n</project_instructions>\n</project_context>"],
        toolsAdded: [.object(["name": .string("read"), "description": .string(text(38))]), .object(["name": .string("ls")])])
    private static let patch = RPCMessage(role: "system", content: [], timestamp: 2, sections: ["docs": String?.none],
                                          toolsRemoved: [.object(["name": .string("ls")])])

    private static func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> RPCMessage {
        RPCMessage(role: "assistant", content: [.toolCall(id: id, name: name, arguments: .object(args))], stopReason: "toolUse", timestamp: 10)
    }

    private static func result(_ id: String, _ name: String, chars: Int) -> RPCMessage {
        RPCMessage(role: "toolResult", content: [.text(text(chars))], toolName: name, toolCallId: id, timestamp: 11)
    }

    @Test func theSplitSeparatesThePromptInstructionsMessagesAndToolResults() {
        let estimate = RPCThreadState.estimate([
            Self.system, Self.patch,
            RPCMessage(role: "user", content: [.text(Self.text(400))], timestamp: 3),
            Self.call("c1", "read", ["path": .string("a.swift")]),
            Self.result("c1", "read", chars: 4000),
        ])
        #expect(estimate.instructionFiles == ["AGENTS.md", "CLAUDE.md"])
        // The preamble alone (docs removed) and the one tool left.
        #expect(estimate.system == (400 + RPCThreadState.jsonLength(.object(["name": .string("read"), "description": .string(Self.text(38))])) + 3) / 4)
        #expect(estimate.instructions > 200 && estimate.instructions < 260)
        #expect(estimate.toolResults == 1000)
        #expect(estimate.messages > 100 && estimate.messages < 120)
        #expect(estimate.total == estimate.system + estimate.instructions + estimate.messages + estimate.toolResults)
    }

    /// The largest results by what they read or ran, the same file's reads counted together and
    /// found at the largest; three at most.
    @Test func theLargestItemsAreNamedByFileOrCommandAndAddUp() {
        let estimate = RPCThreadState.estimate([
            Self.call("r1", "read", ["path": .string("Sources/App/ThreadView.swift")]), Self.result("r1", "read", chars: 2000),
            Self.call("b1", "bash", ["command": .string("swift test --filter Native\nsecond line")]), Self.result("b1", "bash", chars: 6000),
            Self.call("r2", "read", ["path": .string("Other/ThreadView.swift")]), Self.result("r2", "read", chars: 8000),
            Self.call("g1", "grep", ["pattern": .string("x")]), Self.result("g1", "grep", chars: 400),
            Self.call("w1", "write", ["path": .string("tiny.txt")]), Self.result("w1", "write", chars: 40),
        ])
        #expect(estimate.largest == [
            NativeContextItem(entryID: "t:r2", kind: .file, label: "ThreadView.swift", tokens: 2500),
            NativeContextItem(entryID: "t:b1", kind: .command, label: "swift test --filter Native", tokens: 1500),
            NativeContextItem(entryID: "t:g1", kind: .tool, label: "grep", tokens: 100),
        ])
    }

    /// A compaction pi's context starts from: its entry, summary, and the context it replaced.
    @Test func theLatestCompactionIsFoundWithItsSizeBefore() {
        let estimate = RPCThreadState.estimate([
            RPCMessage(role: "compactionSummary", content: [], timestamp: 50, summary: Self.text(400), tokensBefore: 184_000),
            RPCMessage(role: "user", content: [.text("next")], timestamp: 60),
        ])
        #expect(estimate.summaryEntryID == "compactionSummary:50" && estimate.before == 184_000)
        #expect(estimate.messages == 101)
    }

    /// pi lists the summary first, then what it kept; the thread shows it after the kept
    /// messages written before it, and before what came after.
    @Test(arguments: [
        ([("compactionSummary", 30.0), ("user", 10), ("assistant", 20), ("user", 40)], ["user", "assistant", "compactionSummary", "user"]),
        ([("compactionSummary", 30.0), ("user", 40)], ["compactionSummary", "user"]),
        ([("user", 10), ("assistant", 20)], ["user", "assistant"]),
    ] as [([(String, Double)], [String])])
    func aCompactionIsShownWhereItHappened(_ list: [(String, Double)], expected: [String]) {
        let messages = list.map { RPCMessage(role: $0.0, content: [], timestamp: $0.1) }
        #expect(RPCThreadState.chronological(messages).map(\.role) == expected)
    }

    /// After a compaction pi lists only what it kept; what the thread already showed before it
    /// stays readable above, and stays through later refreshes.
    @Test func whatWasSummarizedStaysAboveTheCompaction() {
        func row(_ id: String) -> NativeThreadMessage { NativeThreadMessage(entryID: id, role: id.hasPrefix("c") ? "compactionSummary" : "user", blocks: []) }
        let before = ["a", "b", "k1", "k2"].map(row)
        let first = RPCThreadState.keepingSummarized(previous: before, next: ["k1", "k2", "c:1"].map(row))
        #expect(first.map(\.entryID) == ["a", "b", "k1", "k2", "c:1"])
        let later = RPCThreadState.keepingSummarized(previous: first, next: ["k1", "k2", "c:1", "n"].map(row))
        #expect(later.map(\.entryID) == ["a", "b", "k1", "k2", "c:1", "n"])
        let nothingKept = RPCThreadState.keepingSummarized(previous: before, next: ["c:1"].map(row))
        #expect(nothingKept.map(\.entryID) == ["a", "b", "k1", "k2", "c:1"])
        #expect(RPCThreadState.keepingSummarized(previous: before, next: ["x"].map(row)).map(\.entryID) == ["x"], "no compaction: pi's list as it is")
    }

    /// pi's compaction settings for a model: the project's over the agent directory's, a model's
    /// override over both, and pi's defaults for what is missing or invalid.
    @Test(arguments: [
        (nil, nil, PiCompactionSettings()),
        (#"{"compaction":{"reserveTokens":20000,"enabled":false}}"#, nil, PiCompactionSettings(enabled: false, reserveTokens: 20_000)),
        (#"{"compaction":{"reserveTokens":20000}}"#, #"{"compaction":{"reserveTokens":30000,"keepRecentTokens":5000}}"#,
         PiCompactionSettings(reserveTokens: 30_000, keepRecentTokens: 5_000)),
        (#"{"compaction":{"reserveTokens":20000,"modelOverrides":{"anthropic/opus":{"reserveTokens":400000}}}}"#, nil,
         PiCompactionSettings(reserveTokens: 400_000)),
        (#"{"compaction":{"reserveTokens":-3,"keepRecentTokens":1.5}}"#, nil, PiCompactionSettings()),
        ("not json", nil, PiCompactionSettings()),
    ] as [(String?, String?, PiCompactionSettings)])
    func compactionSettingsFollowPisOrder(_ global: String?, _ project: String?, expected: PiCompactionSettings) throws {
        let agent = try makeTempDirectory()
        let repo = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: agent)
            try? FileManager.default.removeItem(at: repo)
        }
        if let global { try Data(global.utf8).write(to: agent.appendingPathComponent("settings.json")) }
        if let project {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".pi"), withIntermediateDirectories: true)
            try Data(project.utf8).write(to: repo.appendingPathComponent(".pi/settings.json"))
        }
        #expect(PiConfig.compactionSettings(model: "anthropic/opus", cwd: repo.path, in: agent) == expected)
    }

    /// A compaction summary in history carries what the agent kept and the size it replaced.
    @Test func aCompactionSummaryProjectsItsCompaction() {
        let row = RPCThreadState.project(entryID: "compactionSummary:5",
                                         message: RPCMessage(role: "compactionSummary", content: [], timestamp: 5, summary: "## Goal", tokensBefore: 184_000))
        #expect(row.blocks.isEmpty)
        #expect(row.compaction == NativeCompaction(phase: .done, tokensBefore: 184_000, summary: "## Goal"))
    }

    /// pi's system entries never reach the thread.
    @Test func theSystemPromptIsNotHistory() {
        let history = RPCThreadState.projectHistory([Self.system, RPCMessage(role: "user", content: [.text("hi")], timestamp: 3)])
        #expect(history.map(\.role) == ["user"])
    }
}

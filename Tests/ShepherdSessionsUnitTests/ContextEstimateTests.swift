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
        #expect(estimate.messages == 100, "the user's text only: the call's arguments are the agent's own part")
        #expect(estimate.toolCalls > 0 && estimate.toolCalls < 20)
        #expect(estimate.total == estimate.system + estimate.instructions + estimate.messages + estimate.toolResults + estimate.toolCalls)
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

    /// The sizes a compaction reports are pi's numbers as it wrote them: a size past `Int.max` is
    /// `Int.max`, and a negative one is no size.
    @Test(arguments: [
        (184_000.0, 184_000 as Int?), (184_000.7, 184_000), (1e20, .max), (.greatestFiniteMagnitude, .max), (-1, nil),
    ] as [(Double, Int?)])
    func compactionSizesPastAnIntClamp(_ reported: Double, _ expected: Int?) {
        let message = RPCMessage(role: "compactionSummary", content: [], timestamp: 50, summary: "## Goal", tokensBefore: reported)
        #expect(RPCThreadState.estimate([message]).before == expected)
        #expect(RPCThreadState.project(entryID: "compactionSummary:50", message: message).compaction?.tokensBefore == expected)
        let note = RPCThreadState.CompactionNote(summary: "S", reason: .manual,
                                                 result: RPCCompactionResult(summary: "S", tokensBefore: reported, estimatedTokensAfter: reported))
        #expect(note == RPCThreadState.CompactionNote(summary: "S", reason: .manual, before: expected, after: expected))
    }

    /// What the total holds that no part accounts for is `Other`, however large: a context of `Int.max`
    /// from an estimate of one token is one message and the rest unexplained, never "messages".
    @Test func whatNoPartExplainsIsOther() throws {
        let estimate = RPCThreadState.ContextEstimate(messages: 1)
        let huge = try #require(RPCThreadState.scaled(estimate, to: .max)).split
        #expect(huge.messages == 1 && huge.other == .max - 1 && huge.total == .max)
        let split = try #require(RPCThreadState.scaled(estimate, to: 42_000)).split
        #expect(split.messages == 1 && split.other == 41_999 && split.total == 42_000)
        #expect(try #require(RPCThreadState.scaled(estimate, to: nil)).split.other == 0)
        #expect(RPCThreadState.scaled(RPCThreadState.ContextEstimate(), to: 42_000) == nil)
    }

    /// A result clipped or cleared before it was sent is still whole in the messages pi holds, so the parts can
    /// add up to more than the provider's count: the difference comes off the tool results first, and the
    /// largest list follows them. The fixed part is never touched.
    @Test func anExcessComesOffToolResultsFirst() throws {
        let estimate = RPCThreadState.ContextEstimate(
            system: 200, instructions: 100, messages: 100, toolResults: 1_000,
            largest: [NativeContextItem(entryID: "t:a", kind: .file, label: "a.swift", tokens: 800)])
        let scaled = try #require(RPCThreadState.scaled(estimate, to: 900))
        #expect(scaled.split.toolResults == 500 && scaled.split.system == 200 && scaled.split.instructions == 100 && scaled.split.messages == 100)
        #expect(scaled.split.other == 0 && scaled.split.total == 900)
        #expect(scaled.largest.map(\.tokens) == [400])
        // Past the tool results it takes the agent's calls, then reasoning, then images, then messages.
        let more = try #require(RPCThreadState.scaled(RPCThreadState.ContextEstimate(
            system: 200, instructions: 100, messages: 100, toolResults: 100, toolCalls: 50, reasoning: 50, images: 50), to: 450))
        #expect(more.split.toolResults == 0 && more.split.toolCalls == 0 && more.split.reasoning == 0 && more.split.images == 50 && more.split.messages == 100)
    }

    /// A reasoning payload, a screenshot and an agent's written file are their own parts: none of them reads as
    /// the system prompt or the instructions, whatever the provider's total.
    @Test func reasoningImagesAndWrittenFilesAreTheirOwnParts() throws {
        let write = RPCMessage(role: "assistant", content: [
            .thinking(Self.text(40)),
            .toolCall(id: "w1", name: "write", arguments: .object(["path": .string("a.txt"), "content": .string(Self.text(4_000))])),
        ], stopReason: "toolUse", timestamp: 10, usage: RPCUsage(input: 9_000, output: 3_100, reasoning: 3_000))
        let screenshot = RPCMessage(role: "toolResult", content: [.text("ok"), .image(mimeType: "image/png", data: "AAAA")],
                                    toolName: "read", toolCallId: "r1", timestamp: 11)
        let estimate = RPCThreadState.estimate([
            Self.system, RPCMessage(role: "user", content: [.text(Self.text(400))], timestamp: 3), write, screenshot,
        ])
        #expect(estimate.reasoning == 3_000, "the provider's count, not the text kept")
        #expect(estimate.toolCalls > 1_000 && estimate.toolCalls < 1_100)
        #expect(estimate.images == RPCThreadState.imageTokens)
        #expect(estimate.toolResults == 1)
        let split = try #require(RPCThreadState.scaled(estimate, to: estimate.total + 4_000)).split
        #expect(split.system == estimate.system && split.instructions == estimate.instructions)
        #expect(split.other == 4_000 && split.reasoning == 3_000 && split.images == RPCThreadState.imageTokens)
    }

    /// Without the provider's count a reasoning block is its readable text at four characters a token.
    @Test func reasoningWithoutAUsageIsItsText() {
        let thought = RPCMessage(role: "assistant", content: [.thinking(Self.text(400)), .text("ok")], timestamp: 10)
        let estimate = RPCThreadState.estimate([thought])
        #expect(estimate.reasoning == 100 && estimate.messages == 1)
    }

    /// The first call's usage says what the fixed part cost: the prompt it counted, less what the host sizes of
    /// the conversation that call carried. The system prompt, the tools and the instruction files are scaled to
    /// that, and what the total holds beyond all of it is Other.
    @Test func theFixedPartIsAnchoredToTheFirstCallsUsage() throws {
        func reply(_ prompt: Double) -> RPCMessage {
            RPCMessage(role: "assistant", content: [.text(Self.text(40))], stopReason: "stop", timestamp: 10, usage: RPCUsage(input: prompt, output: 10))
        }
        let user = RPCMessage(role: "user", content: [.text(Self.text(400))], timestamp: 3)
        let raw = RPCThreadState.estimate([Self.system, Self.patch, user])
        let fixed = raw.system + raw.instructions
        let measured = fixed + fixed / 4
        let estimate = RPCThreadState.estimate([Self.system, Self.patch, user, reply(Double(measured + 100))])
        #expect(estimate.baseline == RPCThreadState.ContextEstimate.Baseline(prompt: measured + 100, visible: 100))
        let split = try #require(RPCThreadState.scaled(estimate, to: nil)).split
        #expect(split.system + split.instructions == measured)
        let held = try #require(RPCThreadState.scaled(estimate, to: measured + 110 + 500)).split
        #expect(held.other == 500 && held.total == measured + 110 + 500)
        // A count far from the sizing is a call that carried something unsized: the sizing stands.
        let off = RPCThreadState.estimate([Self.system, Self.patch, user, reply(Double(fixed * 5))])
        let unscaled = try #require(RPCThreadState.scaled(off, to: nil)).split
        #expect(unscaled.system == off.system && unscaled.instructions == off.instructions)
    }

    /// An aborted or failed call counts nothing, and a compaction starts a new baseline: the calls before it
    /// carried a context that no longer exists.
    @Test func theBaselineIsTheFirstCountedCallSinceTheLatestCompaction() {
        func reply(_ prompt: Double, _ stop: String, _ at: Double) -> RPCMessage {
            RPCMessage(role: "assistant", content: [.text("ok")], stopReason: stop, timestamp: at, usage: RPCUsage(input: prompt, output: 1))
        }
        let user = RPCMessage(role: "user", content: [.text(Self.text(40))], timestamp: 3)
        let skipped = RPCThreadState.estimate([Self.system, user, reply(5_000, "aborted", 10), reply(6_000, "error", 11), reply(7_000, "stop", 12)])
        #expect(skipped.baseline?.prompt == 7_000)
        let summary = RPCMessage(role: "compactionSummary", content: [], timestamp: 50, summary: Self.text(400), tokensBefore: 9_000)
        let compacted = RPCThreadState.estimate([Self.system, user, reply(9_000, "stop", 10), summary])
        #expect(compacted.baseline == nil, "no call since the compaction has been counted")
        let next = RPCMessage(role: "user", content: [.text(Self.text(40))], timestamp: 60)
        // pi lists only the summary and what came after it.
        let after = RPCThreadState.estimate([Self.system, summary, next, reply(2_500, "stop", 61)])
        #expect(after.baseline?.prompt == 2_500)
        #expect(after.baseline?.visible == 110, "the summary and the message after it: what the call carried besides the fixed part")
    }

    /// The card's lists: each instruction file by where it is and the system prompt's tools by group, largest first.
    @Test func thePromptAndTheInstructionsNameTheirParts() {
        let tools: [JSONValue] = [
            .object(["name": .string("read"), "description": .string(Self.text(400))]),
            .object(["name": .string("browser_open"), "description": .string(Self.text(1_200))]),
            .object(["name": .string("browser_read"), "description": .string(Self.text(1_200))]),
            .object(["name": .string("terminal_run"), "description": .string(Self.text(200))]),
            .object(["name": .string("github_search"), "description": .string(Self.text(100))]),
        ]
        let project = "<project_context>\n<project_instructions path=\"/repo/Docs/AGENTS.md\">\n\(Self.text(2_000))\n</project_instructions>\n"
            + "<project_instructions path=\"/pi/AGENTS.md\">\n\(Self.text(400))\n</project_instructions>\n</project_context>"
        let message = RPCMessage(role: "system", content: [], timestamp: 1,
                                 sections: ["preamble": Self.text(800), "skills": Self.text(1_600), "project_context": project, "addendum": Self.text(200)],
                                 toolsAdded: tools)
        let estimate = RPCThreadState.estimate([message])
        #expect(estimate.systemParts.map(\.label) == ["browser tools", "skills", "pi · system prompt", "pi tools", "terminal tools", "other tools"])
        #expect(estimate.systemParts.map(\.tokens) == estimate.systemParts.map(\.tokens).sorted(by: >))
        #expect(estimate.instructionParts.map(\.label) == ["Docs/AGENTS.md", "pi/AGENTS.md", "APPEND_SYSTEM.md"])
        #expect(estimate.instructionParts.reduce(0) { $0 + $1.tokens } == estimate.instructions)
        #expect(estimate.systemParts.reduce(0) { $0 + $1.tokens } == estimate.system)
    }

    /// An entry id is "<role>:<ms>" from pi's timestamp; one no `Int64` holds keeps its place instead.
    @Test(arguments: [
        (1_758_539_340_000.0, "user:1758539340000"), (1_758_539_340_000.7, "user:1758539340000"), (-0.5, "user:0"),
        (1e20, "m:3"), (-1e20, "m:3"), (.greatestFiniteMagnitude, "m:3"),
    ] as [(Double, String)])
    func entryIDsTakeTimestampsAnInt64Holds(_ timestamp: Double, _ id: String) {
        var seen: [String: Int] = [:]
        let message = RPCMessage(role: "user", content: [.text("hi")], timestamp: timestamp)
        #expect(RPCThreadState.historyEntryID(message, index: 3, seen: &seen) == id)
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

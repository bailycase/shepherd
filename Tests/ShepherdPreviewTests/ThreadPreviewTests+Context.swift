import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

/// The context meter's boards: ContextDetails (the ring's details over the Main thread),
/// ContextFull (almost full), ContextCompacted (a compaction in the thread, the dashed ring), and
/// the ContextIdeas component sheet (ring states, the details' variants, the thread's lines).
extension ThreadPreviewTests {
    static let contextSplit = NativeContextSplit(system: 6_800, instructions: 1_400, messages: 9_100, toolResults: 24_800, instructionFiles: ["AGENTS.md"])
    static let contextLargest = [
        NativeContextItem(entryID: "t:e1", kind: .file, label: "DesktopNativeThreadView.swift", tokens: 8_200),
        NativeContextItem(entryID: "t:b1", kind: .command, label: "swift test --filter NativePresentationTests", tokens: 6_100),
        NativeContextItem(entryID: "t:e3", kind: .file, label: "ThreadView.swift", tokens: 3_400),
    ]

    static func context(tokens: Int?, split: NativeContextSplit? = contextSplit, largest: [NativeContextItem] = contextLargest) -> NativeThreadContext {
        NativeThreadContext(tokens: tokens, window: 200_000, autoCompactAt: 200_000 - 16_384, autoCompact: true, keepRecent: 20_000,
                            split: split, largest: largest)
    }

    static func withContext(_ snapshot: NativeThreadSnapshot, _ context: NativeThreadContext) -> NativeThreadSnapshot {
        var value = snapshot
        value.context = context
        value.supportedActions.append("compact")
        return value
    }

    /// ContextDetails: the Main thread with the ring's details open above it (the split, the
    /// three largest items, the footnote, Compact now…).
    @Test func contextDetails() async throws {
        let fixture = ThreadFixture(Self.withContext(ActivityThreads.idle, Self.context(tokens: 42_000)))
        defer { fixture.store.stop() }
        try await Preview.render("thread-context-details", size: CGSize(width: 1180, height: 900),
                                 ready: { fixture.store.ready && fixture.store.contextDetails != nil }) {
            fixture.thread(contextDetailsOpen: true)
        }
    }

    /// A long thread's context as the host itemizes it (decided by the user, 2026-10-01): the system prompt and the
    /// instruction files with what each is made of, the agent's written files, its reasoning, a screenshot, and
    /// what the provider's total holds beyond all of it as Other, never as "System prompt and tools". Drawn from the
    /// real producer: `RPCThreadState.estimate` over pi's messages (a system entry with sections and tools, usage on
    /// each call) held against the provider's total. Light and dark, and at the largest Text size.
    @Test func contextDetailsBreakdown() async throws {
        func text(_ count: Int) -> String { String(repeating: "x", count: count) }
        func tool(_ name: String, _ chars: Int) -> JSONValue { .object(["name": .string(name), "description": .string(text(chars))]) }
        let project = "<project_context>\n<project_instructions path=\"/Users/me/Developer/Shepherd/AGENTS.md\">\n\(text(19_200))\n</project_instructions>\n"
            + "<project_instructions path=\"/Users/me/Library/Application Support/Shepherd/instructions/AGENTS.md\">\n\(text(2_400))\n</project_instructions>\n</project_context>"
        let browser: [String] = ["browser_open", "browser_read", "browser_click", "browser_type", "browser_press", "browser_scroll", "browser_wait",
                                 "browser_screenshot", "browser_console", "browser_eval", "browser_back", "browser_forward", "browser_reload"]
        let terminal: [String] = ["terminal_list", "terminal_open", "terminal_run", "terminal_read", "terminal_focus", "terminal_close"]
        var tools: [JSONValue] = [tool("read", 700), tool("bash", 900), tool("edit", 800), tool("write", 400)]
        tools += browser.map { tool($0, 1_000) }
        tools += terminal.map { tool($0, 600) }
        tools += [tool("mcp", 1_600), tool("github_search_code", 700)]
        let sections: [String: String?] = ["preamble": text(5_600), "skills": text(3_400), "project_context": project, "addendum": text(900)]
        let system = RPCMessage(role: "system", content: [], timestamp: 1, sections: sections, toolsAdded: tools)
        let user = RPCMessage(role: "user", content: [.text(text(1_600))], timestamp: 3)
        // The first call's count says what the fixed part cost: the sizing agrees with it, so nothing is rescaled.
        let fixed = RPCThreadState.estimate([system, user])
        let firstPrompt = Double(fixed.system + fixed.instructions + 400)
        var calls: [RPCMessage] = []
        for index in 1...6 {
            let arguments: [String: JSONValue] = index == 2
                ? ["path": .string("docs/plan.md"), "content": .string(text(24_000))] : ["command": .string("swift test --filter Native")]
            let block = RPCContentBlock.toolCall(id: "c\(index)", name: index == 2 ? "write" : "bash", arguments: .object(arguments))
            let usage = RPCUsage(input: index == 1 ? firstPrompt : 60_000, output: 3_000, reasoning: 2_500)
            calls.append(RPCMessage(role: "assistant", content: [.thinking(""), block], stopReason: "toolUse", timestamp: Double(10 + index * 2), usage: usage))
        }
        var messages: [RPCMessage] = [system, user]
        for (index, call) in calls.enumerated() {
            messages.append(call)
            var content: [RPCContentBlock] = [.text(text(index == 4 ? 30_000 : 6_000))]
            if index == 3 { content.append(.image(mimeType: "image/png", data: "AAAA")) }
            messages.append(RPCMessage(role: "toolResult", content: content, toolName: index == 1 ? "write" : "bash",
                                       toolCallId: "c\(index + 1)", timestamp: Double(11 + index * 2)))
        }
        let estimate = RPCThreadState.estimate(messages)
        let tokens = estimate.total + 7_200
        let held = try #require(RPCThreadState.scaled(estimate, to: tokens))
        let context = NativeThreadContext(tokens: tokens, window: 200_000, autoCompactAt: 200_000 - 16_384, autoCompact: true, keepRecent: 20_000,
                                          split: held.split, largest: held.largest)
        #expect(held.split.other == 7_200 && held.split.reasoning == 15_000 && held.split.images == RPCThreadState.imageTokens)
        #expect(held.split.toolCalls > 6_000)
        let fixture = ThreadFixture(Self.withContext(ActivityThreads.idle, context))
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("thread-context-breakdown", size: CGSize(width: 1180, height: 1000), scales: [1, 1.3],
                                       ready: { fixture.store.ready && fixture.store.contextDetails != nil }) {
            fixture.thread(contextDetailsOpen: true)
        }
    }

    /// ContextFull: past 85% the details lead with the problem and a field for what to keep.
    @Test func contextAlmostFull() async throws {
        let split = NativeContextSplit(system: 6_800, instructions: 1_400, messages: 31_600, toolResults: 138_200, instructionFiles: ["AGENTS.md"])
        let fixture = ThreadFixture(Self.withContext(ActivityThreads.idle, Self.context(tokens: 178_000, split: split)))
        defer { fixture.store.stop() }
        try await Preview.render("thread-context-full", size: CGSize(width: 1180, height: 900),
                                 ready: { fixture.store.ready && fixture.store.contextDetails?.variant == .almostFull }) {
            fixture.thread(contextDetailsOpen: true)
        }
    }

    /// ContextCompacted: an automatic compaction where it happened, what the agent kept opened
    /// in place, the reply going on below it, and the ring dashed until the agent's next reply.
    @Test func contextCompacted() async throws {
        let t = ActivityThreads.now - 60_000
        var messages = ActivityThreads.idleMessages
        messages.append(ActivityThreads.user("u2", "Looks good. Commit it and push the branch.", at: t))
        messages.append(ActivityThreads.assistant("a2", "Committing the three changed files with a message describing the label removal, then pushing.",
                                       thinking: "Commit, then push.", seconds: 2, at: t + 2_000))
        messages.append(ActivityThreads.tool("c1", "bash", ["command": "git commit -am 'Remove speaker labels'"],
                                  output: "[agent/swiftui-previews 3f2a1c9] Remove speaker labels\n 3 files changed", start: t + 3_000, end: t + 3_400))
        messages.append(ActivityThreads.tool("p1", "bash", ["command": "git push origin agent/swiftui-previews"], output: "To github.com:x/y.git", start: t + 4_000, end: t + 5_000))
        let summary = """
        ## Goal
        Make native thread rows match the spec: no speaker labels, tool rows show a command or path.

        ## Done
        Labels and gutter removed; tool rows show previews. Regression test and Mac Dev build pass. Committed.

        ## Next
        Push the branch, then slash commands and image drops.

        <modified-files>
        Sources/ShepherdApp/DesktopNativeThreadView.swift
        App/iOS/ThreadView.swift
        Tests/ShepherdAppTests/NativePresentationTests.swift
        </modified-files>
        """
        messages.append(NativeThreadMessage(entryID: "compactionSummary:1", role: "compactionSummary", blocks: [], timestamp: t + 6_000,
                                            compaction: NativeCompaction(phase: .done, reason: .threshold, tokensBefore: 184_000,
                                                                         tokensAfter: 23_000, summary: summary)))
        let thinking = ActivityThreads.assistant("a3", "", thinking: "Checking", at: t + 8_000, status: "streaming")
        var snapshot = ActivityThreads.snapshot(messages, provisional: [thinking], running: true)
        var context = Self.context(tokens: nil, split: nil, largest: [])
        context.estimate = 23_000
        context.before = 184_000
        context.summaryEntryID = "compactionSummary:1"
        snapshot = Self.withContext(snapshot, context)
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        fixture.store.compactions.expand("compactionSummary:1")
        try await Preview.render("thread-context-compacted", size: CGSize(width: 1180, height: 900),
                                 ready: { fixture.store.ready && fixture.store.contextMeter?.ring == .estimated }) {
            fixture.thread()
        }
    }

    /// ContextIdeas › The ring and Click for details: every ring state in its button, and the
    /// details' other variants (simple, compacting, just compacted, nothing yet).
    @Test func contextComponents() async throws {
        let rings: [(String, NWContextRingState)] = [
            ("empty", .empty), ("21%", .fill(0.21, .calm)), ("68%", .fill(0.68, .warning)), ("89%", .fill(0.89, .critical)),
            ("compacting", .compacting), ("after compaction", .estimated),
        ]
        var compacting = Self.context(tokens: 184_000)
        compacting.compacting = NativeCompactionRun(reason: .threshold, startedAt: Date().timeIntervalSince1970 * 1000 - 8_000, tokens: 184_000)
        var compacted = Self.context(tokens: nil, split: nil, largest: [])
        compacted.estimate = 23_000
        compacted.before = 184_000
        compacted.summaryEntryID = "c"
        let variants = [
            NativeContextDetails(context: Self.context(tokens: 42_000, split: nil, largest: []), model: "anthropic/claude-opus"),
            NativeContextDetails(context: compacting, model: "anthropic/claude-opus"),
            NativeContextDetails(context: compacted, model: "anthropic/claude-opus"),
            NativeContextDetails(context: Self.context(tokens: nil, split: nil, largest: []), model: "anthropic/claude-opus"),
        ]
        try await Preview.render("context-components", size: CGSize(width: 1400, height: 520)) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    ForEach(rings, id: \.0) { name, state in
                        VStack(spacing: 10) {
                            HStack(spacing: 18) {
                                NWContextMeterButton(state, expanded: false, help: name, accessibilityLabel: name) {}
                                NWContextMeterButton(state, expanded: true, help: name, accessibilityLabel: name) {}
                            }
                            Text(name).font(.nwMono(11)).foregroundStyle(Color.nw.textSecondary)
                        }
                        .frame(width: 190)
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { _, details in
                        NWContextDetails(NWContextDetailsModel(details), actions: NWContextDetailsActions())
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    /// iPad and iPhone: a tap on the ring opens the details as a sheet, as wide as the sheet, with
    /// touch-sized rows and buttons ("tap to find in thread"); and the compaction lines at a
    /// phone's width, where the rules go and Show summary moves under the words.
    @Test func contextTouch() async throws {
        func part(_ label: String, _ tokens: Int) -> NativeContextPart { NativeContextPart(label: label, tokens: tokens) }
        let parts = NativeContextSplit(
            system: 6_800, instructions: 3_000, messages: 9_100, toolResults: 24_800, instructionFiles: ["AGENTS.md"], toolCalls: 3_100,
            reasoning: 6_000, images: 2_100, other: 4_000,
            systemParts: [part("browser tools", 2_300), part("skills", 1_900), part("pi · system prompt", 1_500), part("pi tools", 700)],
            instructionParts: [part("Shepherd/AGENTS.md", 2_000), part("pi/AGENTS.md", 1_000)])
        let split = NativeContextDetails(context: Self.context(tokens: 59_000, split: parts), model: "anthropic/claude-opus")
        let full = NativeContextDetails(context: Self.context(tokens: 178_000, split: NativeContextSplit(
            system: 6_800, instructions: 1_400, messages: 31_600, toolResults: 138_200, instructionFiles: ["AGENTS.md"])), model: "anthropic/claude-opus")
        let rows = [
            NativeCompaction(phase: .done, reason: .threshold, tokensBefore: 184_000, tokensAfter: 23_000, summary: "## Goal\nx"),
            NativeCompaction(phase: .done, reason: .overflow, tokensBefore: 203_000, tokensAfter: 21_000, summary: "## Goal\nx", willRetry: true),
        ].enumerated().map { NativeCompactionRow(entryID: "c\($0.offset)", compaction: $0.element) }
        let summary = NativeCompactionRow(entryID: "open", compaction: NativeCompaction(
            phase: .done, reason: .threshold, tokensBefore: 184_000, tokensAfter: 23_000,
            summary: "## Goal\nMake native thread rows match the spec: no speaker labels, tool rows show a command or path."))
        let expansion = NativeCompactionExpansion()
        expansion.expand("open")
        try await Preview.render("context-touch", size: CGSize(width: 1240, height: 720)) {
            HStack(alignment: .top, spacing: 28) {
                NWContextDetails(NWContextDetailsModel(split), actions: NWContextDetailsActions(), presentation: .sheet)
                    .frame(width: 390).background(Color.nw.bgRaised)
                NWContextDetails(NWContextDetailsModel(full), actions: NWContextDetailsActions(), presentation: .sheet)
                    .frame(width: 390).background(Color.nw.bgRaised)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(rows, id: \.id) { CompactionItem(row: $0) }
                    CompactionItem(row: summary)
                }
                .environment(\.compactionExpansion, expansion)
                .frame(width: 330)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    /// ContextIdeas › In the thread: every compaction line, and what the agent kept.
    @Test func compactionLines() async throws {
        let rows = [
            NativeCompaction(phase: .running, reason: .threshold, tokensBefore: 184_000),
            NativeCompaction(phase: .done, reason: .threshold, tokensBefore: 184_000, tokensAfter: 23_000, summary: "## Goal\nx"),
            NativeCompaction(phase: .done, reason: .manual, tokensBefore: 92_000, tokensAfter: 14_000, summary: "## Goal\nx"),
            NativeCompaction(phase: .done, reason: .overflow, tokensBefore: 203_000, tokensAfter: 21_000, summary: "## Goal\nx", willRetry: true),
            NativeCompaction(phase: .stopped, reason: .manual),
        ].enumerated().map { NativeCompactionRow(entryID: "c\($0.offset)", compaction: $0.element) }
        let summary = NativeCompactionRow(entryID: "open", compaction: NativeCompaction(
            phase: .done, reason: .threshold, tokensBefore: 184_000, tokensAfter: 23_000,
            summary: "## Goal\nMake native thread rows match the spec: no speaker labels, tool rows show a command or path.\n\n## Done\nLabels and gutter removed; tool rows show previews. Regression test and Mac Dev build pass. Committed.\n\n## Next\nPush the branch, then slash commands and image drops.\n\n<modified-files>\nDesktopNativeThreadView.swift\nThreadView.swift\nNativePresentationTests.swift\n</modified-files>"))
        let expansion = NativeCompactionExpansion()
        expansion.expand("open")
        try await Preview.render("thread-compaction-lines", size: CGSize(width: 900, height: 620)) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows, id: \.id) { CompactionItem(row: $0) }
                CompactionItem(row: summary)
            }
            .environment(\.compactionExpansion, expansion)
            .padding(28)
            .frame(width: 900, height: 620, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }
}

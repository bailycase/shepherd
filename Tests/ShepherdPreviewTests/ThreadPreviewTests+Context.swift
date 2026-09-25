import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

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

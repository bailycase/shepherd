import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The context meter on iPad and iPhone (ContextIdeas, ContextDetails, ContextFull,
// ContextCompacted): the ring beside Send, and its details as a sheet. Nothing here asks the host
// to compact.
extension FixtureCatalog {
    static var context: [FixtureScreen] {
        let preview = FixtureData.ref(FixtureData.preview)
        let open: @MainActor (MobileApp) async -> Void = { _ in ComposerStates.shared.state(for: preview).showingContext = true }
        return [
            // The ring at 68% (amber) beside Send, the details closed.
            FixtureScreen(name: "context-ring", hosts: ThreadFixtures.hosts(preview: ContextFixtures.details(tokens: 136_000)),
                          routes: [.thread(preview)]),
            // ContextDetails: the split, the three largest items, the footnote, Compact now….
            FixtureScreen(name: "context-details", hosts: ThreadFixtures.hosts(preview: ContextFixtures.details(tokens: 42_000)),
                          routes: [.thread(preview)], prepare: open),
            // ContextFull: past 85% the details lead with the problem and a field for what to keep.
            FixtureScreen(name: "context-full", hosts: ThreadFixtures.hosts(preview: ContextFixtures.full()),
                          routes: [.thread(preview)], prepare: open),
            // Compacting: the ring turns, the line shimmers, and the details have nothing to press.
            FixtureScreen(name: "context-compacting", hosts: ThreadFixtures.hosts(preview: ContextFixtures.compacting()),
                          routes: [.thread(preview)], prepare: open),
            // ContextCompacted: the compaction where it happened with what the agent kept open,
            // the reply going on under it, and the ring dashed until the next reply.
            FixtureScreen(name: "context-compacted", hosts: ThreadFixtures.hosts(preview: ContextFixtures.compacted()),
                          routes: [.thread(preview)],
                          prepare: { app in app.threads.store(for: preview).compactions.expand(ContextFixtures.summaryID) }),
            // The same, with the ring's details: the estimate and Show summary.
            FixtureScreen(name: "context-compacted-details", hosts: ThreadFixtures.hosts(preview: ContextFixtures.compacted()),
                          routes: [.thread(preview)], prepare: open),
        ]
    }
}

enum ContextFixtures {
    static let summaryID = "compactionSummary:1"

    static let split = NativeContextSplit(system: 6_800, instructions: 1_400, messages: 9_100, toolResults: 24_800,
                                          instructionFiles: ["AGENTS.md"])
    /// The MobileThread board's own tool results (ThreadFixtures.thread), as the boards size them.
    static let largest = [
        NativeContextItem(entryID: "m3", kind: .file, label: "DesktopNativeThreadView.swift", tokens: 8_200),
        NativeContextItem(entryID: "m5", kind: .command, label: "swift test --filter ThreadRows", tokens: 6_100),
        NativeContextItem(entryID: "m4", kind: .file, label: "ThreadView.swift", tokens: 3_400),
    ]

    static func context(tokens: Int?, split: NativeContextSplit? = split, largest: [NativeContextItem] = largest) -> NativeThreadContext {
        NativeThreadContext(tokens: tokens, window: 200_000, autoCompactAt: 200_000 - 16_384, autoCompact: true, keepRecent: 20_000,
                            split: split, largest: largest)
    }

    static func with(_ snapshot: NativeThreadSnapshot, _ context: NativeThreadContext) -> NativeThreadSnapshot {
        var value = snapshot
        value.context = context
        value.supportedActions.append("compact")
        return value
    }

    /// The MobileThread board's finished turn, with the context at `tokens`: the boards' split at
    /// 42k, and more tool results as it fills.
    static func details(tokens: Int) -> NativeThreadSnapshot {
        let messages = max(split.messages, tokens / 6)
        let grown = NativeContextSplit(system: split.system, instructions: split.instructions, messages: messages,
                                       toolResults: tokens - split.system - split.instructions - messages, instructionFiles: split.instructionFiles)
        return with(ThreadFixtures.thread(), context(tokens: tokens, split: tokens == split.total ? split : grown))
    }

    /// ContextFull: 178k of 200k, tool results 138k of it.
    static func full() -> NativeThreadSnapshot {
        let split = NativeContextSplit(system: 6_800, instructions: 1_400, messages: 31_600, toolResults: 138_200,
                                       instructionFiles: ["AGENTS.md"])
        return with(ThreadFixtures.thread(), context(tokens: 178_000, split: split))
    }

    /// pi compacting on its own at 184k, eight seconds in.
    static func compacting() -> NativeThreadSnapshot {
        typealias F = FixtureData
        let now = Date().timeIntervalSince1970 * 1000
        var snapshot = ThreadFixtures.thread()
        snapshot.messages.append(F.user("u2", "Now add the same previews to the iPad thread.", at: now - F.start - 40_000))
        snapshot.provisional = [NativeThreadMessage(entryID: "compaction:live", role: "compaction", blocks: [], timestamp: now - 8_000,
                                                    compaction: NativeCompaction(phase: .running, reason: .threshold, tokensBefore: 184_000))]
        snapshot.running = true
        var context = context(tokens: 184_000)
        context.compacting = NativeCompactionRun(reason: .threshold, startedAt: now - 8_000, tokens: 184_000)
        return with(snapshot, context)
    }

    /// ContextCompacted: the push, the compaction pi made on its own, and the next reply thinking.
    static func compacted() -> NativeThreadSnapshot {
        typealias F = FixtureData
        var snapshot = ThreadFixtures.thread()
        // A minute ago, so the running clock reads as the board's.
        let t = Date().timeIntervalSince1970 * 1000 - F.start - 60_000
        snapshot.messages += [
            F.user("u2", "Looks good. Commit it and push the branch.", at: t),
            F.assistant("a2", "Committing the three changed files with a message describing the label removal, then pushing.",
                        thinking: "Commit, then push.", seconds: 2, at: t + 2_000),
            F.tool("c1", "bash", args: #"{"command":"git commit -am 'Remove speaker labels'"}"#,
                   output: "[agent/swiftui-previews 3f2a1c9] Remove speaker labels\n 3 files changed", at: t + 3_400),
            F.tool("p1", "bash", args: #"{"command":"git push origin agent/swiftui-previews"}"#, output: "To github.com:x/y.git", at: t + 5_000),
            NativeThreadMessage(entryID: summaryID, role: "compactionSummary", blocks: [], timestamp: F.start + t + 6_000,
                                compaction: NativeCompaction(phase: .done, reason: .threshold, tokensBefore: 184_000, tokensAfter: 23_000,
                                                             summary: summary)),
        ]
        snapshot.provisional = [F.assistant("a3", "", thinking: "Checking", at: t + 8_000, status: "streaming")]
        snapshot.running = true
        var context = context(tokens: nil, split: nil, largest: [])
        context.estimate = 23_000
        context.before = 184_000
        context.summaryEntryID = summaryID
        return with(snapshot, context)
    }

    static let summary = """
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
}

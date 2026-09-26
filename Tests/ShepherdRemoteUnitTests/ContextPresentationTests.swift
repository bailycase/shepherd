import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The context meter's presentation (ContextIdeas, ContextDetails, ContextFull,
/// ContextCompacted): the ring's state and tooltip, the details' variants, and compactions in the
/// thread.
@Suite("Context meter presentation")
struct ContextPresentationTests {
    static let split = NativeContextSplit(system: 6_800, instructions: 1_400, messages: 9_100, toolResults: 24_800, instructionFiles: ["AGENTS.md"])

    static func context(tokens: Int?, window: Int? = 200_000, split: NativeContextSplit? = nil, auto: Bool = true) -> NativeThreadContext {
        NativeThreadContext(tokens: tokens, window: window, autoCompactAt: auto ? 183_616 : nil, autoCompact: auto, keepRecent: 20_000, split: split)
    }

    /// Under 60% grey, 60 to 85% amber, over 85% red.
    @Test(arguments: [
        (0.0, NativeContextMeter.Tone.calm), (59.9, .calm), (60, .warning), (85, .warning), (85.1, .critical), (100, .critical),
    ])
    func theRingsToneFollowsTheBoardsThresholds(_ percent: Double, tone: NativeContextMeter.Tone) {
        #expect(NativeContextMeter.tone(percent: percent) == tone)
    }

    @Test(arguments: [
        (42_000, NativeContextMeter.Ring.fill(0.21, .calm), "42k of 200k · 21%", nil as String?, "Context 21% full"),
        (136_000, .fill(0.68, .warning), "136k of 200k · 68%", nil, "Context 68% full"),
        (178_000, .fill(0.89, .critical), "178k of 200k · 89%", nil, "Context 89% full"),
    ])
    func aNumberFillsTheRingAndTheTooltipSaysIt(_ tokens: Int, ring: NativeContextMeter.Ring, tooltip: String, note: String?, label: String) throws {
        let meter = try #require(NativeContextMeter(Self.context(tokens: tokens)))
        #expect(meter.ring == ring && meter.tooltip == tooltip && meter.tooltipNote == note && meter.accessibilityLabel == label)
    }

    /// pi's percent is tokens over a window it passes through as written, so a tiny window makes
    /// it enormous: the text stays a whole number from 0 to 100.
    @Test(arguments: [
        (21.4, "21%"), (61.6, "62%"), (0, "0%"), (100, "100%"), (100.4, "100%"), (125, "100%"), (8.123e23, "100%"),
        (.greatestFiniteMagnitude, "100%"), (.infinity, "100%"), (-4, "0%"), (-.greatestFiniteMagnitude, "0%"), (.nan, "0%"),
    ] as [(Double, String)])
    func aPercentIsWholeAndWithinAHundred(_ percent: Double, text: String) {
        #expect(nativeContextPercentText(percent) == text)
    }

    /// A models.json "unlimited" window (1e20, clamped to `Int.max`) or one of a single token
    /// still draws a ring, a tooltip, and details.
    @Test(arguments: [
        (8_123, Int.max, NativeContextMeter.Ring.fill(8_123 / Double(Int.max), .calm), "0%"),
        (Int.max, Int.max, .fill(1, .critical), "100%"),
        (Int.max, 1, .fill(1, .critical), "100%"),
        (8_123, 1, .fill(1, .critical), "100%"),
    ])
    func windowsAtEitherExtremeStillDraw(_ tokens: Int, _ window: Int, ring: NativeContextMeter.Ring, percent: String) throws {
        let context = Self.context(tokens: tokens, window: window, split: Self.split)
        let meter = try #require(NativeContextMeter(context))
        #expect(meter.ring == ring)
        #expect(meter.tooltip.hasSuffix(" · " + percent) && meter.accessibilityLabel == "Context \(percent) full")
        let details = NativeContextDetails(context: context, model: "anthropic/claude-opus")
        #expect(details.trailing == percent)
        #expect(details.segments.allSatisfy { (0...1).contains($0.fraction) })
        #expect(details.mark.map { (0...1).contains($0) } ?? true)
    }

    /// No number yet is the empty track; after a compaction, the dashed ring with the agent's
    /// estimate; while compacting, the spinning arc. An older host sends no context: no ring.
    @Test func theRingsOtherStates() throws {
        #expect(NativeContextMeter(nil) == nil)
        let empty = try #require(NativeContextMeter(Self.context(tokens: nil)))
        #expect(empty.ring == .empty && empty.accessibilityLabel == "Context: nothing yet")
        var compacted = Self.context(tokens: nil)
        compacted.estimate = 23_000
        let estimated = try #require(NativeContextMeter(compacted))
        #expect(estimated.ring == .estimated && estimated.tooltip == "about 23k of 200k" && estimated.tooltipNote == "exact after the next reply")
        #expect(estimated.helpText == "about 23k of 200k · exact after the next reply")
        #expect(NativeContextMeter(compacted, replying: true)?.tooltipNote == "exact after this reply")
        var running = Self.context(tokens: 184_000)
        running.compacting = NativeCompactionRun(reason: .threshold, startedAt: 0, tokens: 184_000)
        let compacting = try #require(NativeContextMeter(running))
        #expect(compacting.ring == .compacting && compacting.tooltip == "Compacting 184k…" && compacting.accessibilityLabel == "Context: compacting")
    }

    @Test(arguments: [(812, "812"), (1_000, "1k"), (6_849, "6.8k"), (24_800, "24.8k"), (99_949, "99.9k"), (158_000, "158k"), (1_200_000, "1.2m")])
    func detailsListTokensToATenth(_ tokens: Int, text: String) {
        #expect(nativePreciseTokens(tokens) == text)
    }

    /// The total, the window and the mark round to the nearest thousand: a 200k window less pi's
    /// 16,384 reserve is the boards' "184k".
    @Test(arguments: [(812, "812"), (42_137, "42k"), (183_616, "184k"), (200_000, "200k"), (999_600, "1m"), (1_048_576, "1m")])
    func contextSizesRoundToTheNearestThousand(_ tokens: Int, text: String) {
        #expect(nativeContextTokens(tokens) == text)
    }

    /// ContextDetails(.split): the total of the window, the bar with the mark, the split with
    /// what is free, the largest items, and the footnote.
    @Test func theSplitDetailsAreTheBoards() {
        var context = Self.context(tokens: 42_000, split: Self.split)
        context.largest = [NativeContextItem(entryID: "t:c1", kind: .file, label: "DesktopNativeThreadView.swift", tokens: 8_200)]
        let details = NativeContextDetails(context: context, model: "anthropic/claude-opus")
        #expect(details.variant == .split && details.title == "Context" && details.meta == "claude-opus · 200k")
        #expect(details.total == "42k" && details.ofWindow == "of 200k" && details.trailing == "21%")
        #expect(details.markLabel == "auto-compact · 184k ↑" && abs((details.mark ?? 0) - 0.918) < 0.001)
        #expect(details.rows.map(\.label) == ["System prompt and tools", "Instructions · AGENTS.md", "Messages", "Tool results"])
        #expect(details.rows.map(\.value) == ["6.8k", "1.4k", "9.1k", "24.8k"])
        #expect(details.free == "158k")
        #expect(details.segments.map(\.part) == [.system, .instructions, .messages, .toolResults])
        #expect(details.largest.map(\.value) == ["8.2k"])
        #expect(details.footnote == "The total is the agent’s. The split is Shepherd’s estimate from the messages.")
    }

    /// Past 85% the details lead with the problem, naming the biggest part and the mark.
    @Test(arguments: [
        (true, "Tool results are 138k of it. The agent will compact on its own at 184k, before its next reply. Compact now to say what the summary should keep."),
        (false, "Tool results are 138k of it. The agent will not compact on its own. Compact now to say what the summary should keep."),
    ])
    func almostFullSaysWhatFillsItAndWhatHappensNext(_ auto: Bool, note: String) {
        let split = NativeContextSplit(system: 6_800, instructions: 1_400, messages: 31_600, toolResults: 138_200)
        let details = NativeContextDetails(context: Self.context(tokens: 178_000, split: split, auto: auto), model: nil)
        #expect(details.variant == .almostFull && details.title == "Context almost full" && details.total == "178k" && details.trailing == "89%")
        #expect(details.note == note && details.rows.isEmpty && details.largest.isEmpty)
    }

    @Test func compactingAndJustCompactedHaveTheirOwnDetails() {
        var running = Self.context(tokens: 184_000)
        running.compacting = NativeCompactionRun(reason: .threshold, startedAt: 5_000, tokens: 184_000)
        let compacting = NativeContextDetails(context: running, model: nil)
        #expect(compacting.variant == .compacting(startedAt: 5_000) && compacting.title == "Compacting" && !compacting.compactOffered)
        #expect(compacting.note == "Summarizing 184k into a short brief. The last 20k stay as they are.")

        var after = Self.context(tokens: nil)
        after.estimate = 23_000
        after.before = 184_000
        after.summaryEntryID = "compactionSummary:9"
        let compacted = NativeContextDetails(context: after, model: nil)
        #expect(compacted.variant == .compacted && compacted.meta == "just compacted" && compacted.total == "~23k" && compacted.trailing == "estimate")
        #expect(compacted.note == "The agent reports the exact number after its next reply. Was 184k." && compacted.summaryEntryID == "compactionSummary:9")

        let empty = NativeContextDetails(context: Self.context(tokens: nil), model: nil)
        #expect(empty.variant == .empty && empty.total == nil)
        #expect(NativeContextDetails(context: Self.context(tokens: 42_000), model: nil).variant == .simple)
    }

    /// The divider's words follow why pi compacted (ContextIdeas › In the thread).
    @Test(arguments: [
        (NativeCompaction(phase: .done, reason: .threshold, tokensBefore: 184_000, tokensAfter: 23_000, summary: "s"),
         "Compacted automatically", "184k → 23k" as String?, NativeCompactionRow.Tone.normal),
        (NativeCompaction(phase: .done, reason: .manual, tokensBefore: 92_000, tokensAfter: 14_000, summary: "s"), "You compacted", "92k → 14k", .normal),
        (NativeCompaction(phase: .done, reason: .overflow, tokensBefore: 203_000, tokensAfter: 21_000, summary: "s", willRetry: true),
         "Context overflowed · compacted and retried", "203k → 21k", .warning),
        (NativeCompaction(phase: .done, tokensBefore: 184_000, summary: "s"), "Compacted", "184k", .normal),
        (NativeCompaction(phase: .stopped, reason: .manual), "Compaction stopped · nothing changed", nil, .quiet),
        (NativeCompaction(phase: .failed, reason: .manual, error: "Compaction failed: too small"), "Compaction failed · nothing changed", nil, .quiet),
        (NativeCompaction(phase: .running, reason: .threshold, tokensBefore: 184_000), "Compacting context…", "184k", .normal),
    ])
    func compactionLinesSayWhatHappened(_ compaction: NativeCompaction, title: String, tokens: String?, tone: NativeCompactionRow.Tone) {
        let row = NativeCompactionRow(entryID: "e", compaction: compaction)
        #expect(row.title == title && row.tokens == tokens && row.tone == tone)
        #expect(row.running == (compaction.phase == .running))
        #expect(row.sections.isEmpty == (compaction.phase != .done))
    }

    /// What the agent kept, in its own sections; the files it changed by name, the files it read
    /// left out.
    @Test func theSummaryKeepsTheAgentsSectionsAndNamesTheFilesItChanged() {
        let summary = """
        ## Goal
        Make the rows match the **spec**.

        ## Progress
        ### Done
        - Labels removed

        <read-files>
        Sources/A.swift
        </read-files>

        <modified-files>
        Sources/App/ThreadView.swift
        Tests/NativePresentationTests.swift
        </modified-files>
        """
        let sections = nativeSummarySections(summary)
        #expect(sections.map(\.title) == ["Goal", "Progress", "Done", "Files changed"])
        #expect(String(sections[0].text.characters) == "Make the rows match the spec.")
        #expect(sections[3].files == ["ThreadView.swift", "NativePresentationTests.swift"])
        #expect(!sections.contains { String($0.text.characters).contains("A.swift") })
        let row = NativeCompactionRow(entryID: "e", compaction: NativeCompaction(phase: .done, reason: .manual, summary: summary))
        #expect(row.summary == summary && row.summarySize == nativePreciseTokens((summary.utf8.count + 3) / 4))
    }

    /// A compaction is its own item in the reply where it happened, between the work around it.
    @Test func aCompactionIsAnItemOfItsTurn() {
        let messages = [
            NativeThreadMessage(entryID: "a", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Committing.")]),
            NativeThreadMessage(entryID: "compactionSummary:5", role: "compactionSummary", blocks: [],
                                compaction: NativeCompaction(phase: .done, reason: .threshold, tokensBefore: 184_000, summary: "## Goal\nx")),
            NativeThreadMessage(entryID: "b", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Pushed.")]),
        ]
        #expect(nativeTurns(messages).count == 1)
        let items = nativeTurnPresentation(messages, live: false).items
        #expect(items.map(\.id) == ["prose:0", "compaction:compactionSummary:5", "prose:1"])
    }

    @Test func expandingACompactionIsRemembered() async {
        await MainActor.run {
            let expansion = NativeCompactionExpansion()
            expansion.toggle("c")
            #expect(expansion.isExpanded("c"))
            expansion.expand("c")
            expansion.toggle("c")
            #expect(!expansion.isExpanded("c"))
        }
    }
}

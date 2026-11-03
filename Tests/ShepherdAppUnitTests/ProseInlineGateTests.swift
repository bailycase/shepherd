import Foundation
import Testing
import ShepherdRemote
import ShepherdUI
@testable import ShepherdApp

/// Inline Markdown of prose is parsed off the main actor, cold or on screen, its parses kept with
/// the blocks they draw whatever the cache admits, and the styled caches are bounded by cost.
@Suite("Prose inline preparation", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ProseInlineGateTests {
    private func paragraph(_ kib: Int, _ tag: String) -> String {
        // Mostly words, styled now and then, as a long answer reads.
        String(repeating: String(repeating: "words in a sentence ", count: 48) + "**bold** `code` [link](https://example.com) \(tag) ",
               count: kib * 1024 / 1024)
    }

    /// Counts landings and lets a test await the next one.
    @MainActor final class Landings {
        var count = 0
        var next: CheckedContinuation<Void, Never>?
        func land() { count += 1; next?.resume(); next = nil }
        func until(_ start: () -> Void) async { await withCheckedContinuation { next = $0; start() } }
    }

    /// A prepare the test releases by hand (a release before it starts waiting is kept); it then
    /// parses for real, off the main actor.
    @MainActor final class Controlled {
        var calls: [[String]] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var permits = 0
        var prepare: ProseInlineGate.Prepare {
            { texts in
                await self.hold(texts)
                return await SHProseInline.prepare(texts)
            }
        }
        private func hold(_ texts: [String]) async {
            calls.append(texts)
            if permits > 0 { permits -= 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            if waiting.isEmpty { permits += 1 }
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// Styles what the gate shows the way `Prose` does, returning the main-actor parses it cost.
    private func draw(_ shown: ProseInlineGate.Shown) -> Int {
        let before = SHProseInline.mainParses
        _ = Prose.proseBlocks(shown.blocks, inline: shown.attributed)
        return SHProseInline.mainParses - before
    }

    @Test func growingTextKeepsTheLastBlocksUntilItsParseLands() async {
        let gate = ProseInlineGate()
        let first: [NativeMarkdownBlock] = [.paragraph("Short \(UUID())")]
        #expect(gate.blocks(for: first) {}.blocks == first, "small prose draws at once")
        for kib in [16, 64] {
            let grown: [NativeMarkdownBlock] = [.paragraph(paragraph(kib, UUID().uuidString)), .table(NativeMarkdownTable(
                alignments: [.none], header: ["`a`"], rows: [["**b**"]], source: ""))]
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let shown = gate.blocks(for: grown) { done.resume() }
                #expect(shown.blocks != grown, "the previous presentation stays while \(kib) KiB parses off main")
            }
            let shown = gate.blocks(for: grown) {}
            #expect(shown.blocks == grown)
            #expect(draw(shown) == 0, "parsed off main before it is drawn: styling parses nothing on main")
        }
        // Small changes draw at once, and links and styling survive the prepared path.
        let small: [NativeMarkdownBlock] = [.paragraph("[x](https://example.com) \(UUID())")]
        let shown = gate.blocks(for: small) {}
        #expect(shown.blocks == small)
        guard case .paragraph(let styled)? = Prose.proseBlocks(shown.blocks, inline: shown.attributed).first else {
            Issue.record("not a paragraph"); return
        }
        #expect(styled.runs.contains { $0.link != nil })
    }

    /// Prose seen for the first time (a row scrolled back in, a thread opened) never parses a
    /// large text on main: it draws plain, then styled once the parse lands.
    @Test func coldLargeProseDrawsPlainThenStyledWithoutAMainParse() async {
        let gate = ProseInlineGate()
        let landings = Landings()
        let text = paragraph(32, UUID().uuidString)
        let blocks: [NativeMarkdownBlock] = [.paragraph(text)]
        var cold: ProseInlineGate.Shown?
        await landings.until { cold = gate.blocks(for: blocks) { landings.land() } }
        guard let cold else { Issue.record("no first draw"); return }
        #expect(cold.blocks == blocks && cold.plain == [text], "the new blocks draw at once, their text plain")
        #expect(draw(cold) == 0)
        #expect(String(cold.attributed(text).characters) == text)
        #expect(gate.offMainParses == 1)
        let landed = gate.blocks(for: blocks) {}
        #expect(landed.plain.isEmpty)
        #expect(draw(landed) == 0, "the landed parse styles without parsing on main")
        guard case .paragraph(let styled)? = Prose.proseBlocks(landed.blocks, inline: landed.attributed).first else {
            Issue.record("not a paragraph"); return
        }
        #expect(styled.runs.contains { $0.link != nil }, "styled, not left plain")
    }

    /// A text past the cache's entry budget is never cached; the gate keeps its parse, so neither
    /// its first draw, a redraw, nor a later chunk below it parses it on main.
    @Test func oversizeProseIsKeptByTheGateNotTheCache() async {
        // Mostly plain, so its few runs style quickly: its size alone puts it past the budget.
        let huge = String(repeating: "plain words ", count: SHProseInline.entryCostLimit / 20) + "**bold** \(UUID())"
        let gate = ProseInlineGate()
        let landings = Landings()
        let blocks: [NativeMarkdownBlock] = [.paragraph(huge)]
        await landings.until { #expect(draw(gate.blocks(for: blocks) { landings.land() }) == 0) }
        #expect(!SHProseInline.isPrepared(huge), "past the entry budget: never cached")
        #expect(draw(gate.blocks(for: blocks) {}) == 0)
        #expect(draw(gate.blocks(for: blocks) {}) == 0, "a redraw styles the kept parse again")
        let small = "then `more` \(UUID())"
        let grown = gate.blocks(for: blocks + [.paragraph(small)]) {}
        #expect(grown.blocks.count == 2, "a small chunk below it draws at once")
        #expect(draw(grown) == 1, "only the small new text parses on main")
        // Dropping the paragraph drops its parse: retention follows the drawn blocks.
        let after = gate.blocks(for: [.paragraph(small)]) {}
        #expect(after.parsed[huge] == nil)
    }

    /// Rapid chunks run one parse at a time and land the newest next; a change drawn at once
    /// cancels the parse in flight and its late result never replaces what is drawn.
    @Test func rapidChangesAreBoundedAndALateParseNeverWins() async {
        let controlled = Controlled()
        let gate = ProseInlineGate(prepare: controlled.prepare)
        let landings = Landings()
        let start: [NativeMarkdownBlock] = [.paragraph("Start \(UUID())")]
        _ = gate.blocks(for: start) {}
        let chunks = (0..<4).map { [NativeMarkdownBlock.paragraph(paragraph(16 + $0, UUID().uuidString))] }
        for chunk in chunks {
            #expect(gate.blocks(for: chunk) { landings.land() }.blocks == start, "the last blocks stay drawn")
        }
        #expect(gate.offMainParses == 1, "one parse in flight, never one per chunk")
        await landings.until { controlled.release() }
        #expect(controlled.calls.count == 1)
        #expect(gate.shown?.blocks == chunks[0], "the parse that landed draws, ahead of the stream")
        // The newest chunk parses next; a small change meanwhile draws at once and wins.
        #expect(gate.blocks(for: chunks[3]) { landings.land() }.blocks == chunks[0])
        #expect(gate.offMainParses == 2)
        let small: [NativeMarkdownBlock] = [.paragraph("Reset \(UUID())")]
        #expect(gate.blocks(for: small) {}.blocks == small)
        controlled.release()
        await gate.cancelled?.value
        #expect(gate.shown?.blocks == small, "the cancelled parse never replaces the newer blocks")
        #expect(landings.count == 1)
        #expect(controlled.calls.count <= 2, "the cancelled parse was the last one started")
    }

    @Test func oversizeTextIsStyledButNeverCached() {
        let huge = String(repeating: "x", count: SHProseInline.entryCostLimit)
        let once = SHProseInline.attributed(huge)
        #expect(String(once.characters) == huge)
        #expect(!SHProseInline.isPrepared(huge), "past the entry budget: recomputed, never retained")
        let small = "`kept` \(UUID())"
        _ = SHProseInline.attributed(small)
        #expect(SHProseInline.isPrepared(small))
    }
}

import Foundation
import Testing
import ShepherdRemote
import ShepherdUI
@testable import ShepherdApp

/// Inline Markdown of prose already on screen is parsed off the main actor, and the styled
/// caches are bounded by cost, not just by entries.
@Suite("Prose inline preparation", .serialized)
@MainActor
struct ProseInlineGateTests {
    private func paragraph(_ kib: Int, _ tag: String) -> String {
        // Mostly words, styled now and then, as a long answer reads.
        String(repeating: String(repeating: "words in a sentence ", count: 48) + "**bold** `code` [link](https://example.com) \(tag) ",
               count: kib * 1024 / 1024)
    }

    @Test func growingTextKeepsTheLastBlocksUntilItsParseLands() async {
        let gate = ProseInlineGate()
        let first: [NativeMarkdownBlock] = [.paragraph("Short \(UUID())")]
        #expect(gate.blocks(for: first) {} == first, "first sight draws at once")
        for kib in [16, 64, 256] {
            let grown: [NativeMarkdownBlock] = [.paragraph(paragraph(kib, UUID().uuidString)), .table(NativeMarkdownTable(
                alignments: [.none], header: ["`a`"], rows: [["**b**"]], source: ""))]
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let shown = gate.blocks(for: grown) { done.resume() }
                #expect(shown != grown, "the previous presentation stays while \(kib) KiB parses off main")
            }
            #expect(gate.blocks(for: grown) {} == grown)
            // Parsed off main before it is drawn: styling it on the main actor parses nothing.
            #expect(Prose.inlineTexts(grown).allSatisfy(SHProseInline.isPrepared))
        }
        // Small changes draw at once, and links and styling survive the prepared path.
        let small: [NativeMarkdownBlock] = [.paragraph("[x](https://example.com) \(UUID())")]
        #expect(gate.blocks(for: small) {} == small)
        guard case .paragraph(let styled)? = Prose.proseBlocks(small).first else { Issue.record("not a paragraph"); return }
        #expect(styled.runs.contains { $0.link != nil })
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

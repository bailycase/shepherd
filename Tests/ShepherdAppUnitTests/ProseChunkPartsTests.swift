import Foundation
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A chunk's blocks keep their views while the reply grows: each takes the id of the part it came from.
@Suite("Prose chunk parts")
@MainActor
struct ProseChunkPartsTests {
    private func ids(_ parts: [SHProsePart]) -> [SHProsePart.ID] { parts.map(\.id) }

    @Test func theBlocksDrawnTakeThePartIdsOfTheirChunkByPosition() throws {
        let items = (1...40).map { "- item \($0)" }.joined(separator: "\n")
        let prose = NativeProse(nativeMarkdownBlocks("Intro\n\n" + items + "\n\nAfter"))
        #expect(prose.chunks.count == 2, "the list's second stretch starts a chunk")
        let first = prose.chunks[0], second = prose.chunks[1]

        let drawn = Prose.proseBlocks(first.blocks)
        #expect(ids(ProseChunk.parts(of: first, drawing: drawn)) == first.parts.map { .init(block: $0.id.block, stretch: $0.id.stretch) })
        #expect(ids(ProseChunk.parts(of: second, drawing: Prose.proseBlocks(second.blocks))).first == .init(block: 1, stretch: 1),
                "a stretch of a list keeps its id")
    }

    /// While an inline parse is pending the gate keeps the last blocks drawn, from a longer or shorter text than the chunk's.
    @Test func staleBlocksPastTheChunkTakeTheNextOrdinalsAndMissingOnesDrawNothing() throws {
        let prose = NativeProse(nativeMarkdownBlocks("One\n\nTwo\n\nThree"))
        let chunk = try #require(prose.chunks.first)
        let drawn = Prose.proseBlocks(chunk.blocks)
        #expect(drawn.count == 3)

        let longer = ProseChunk.parts(of: chunk, drawing: drawn + [.rule, .rule])
        #expect(ids(longer) == (0..<5).map { .init(block: $0, stretch: 0) })
        #expect(longer.prefix(3).map(\.block) == drawn)

        let shorter = ProseChunk.parts(of: chunk, drawing: Array(drawn.prefix(1)))
        #expect(ids(shorter) == [.init(block: 0, stretch: 0)])
        #expect(ProseChunk.parts(of: chunk, drawing: []).isEmpty)
    }
}

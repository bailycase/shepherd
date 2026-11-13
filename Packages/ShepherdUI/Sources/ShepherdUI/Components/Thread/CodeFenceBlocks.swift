import Foundation
import SwiftUI

/// A fence a reply is still writing, cut into blocks of finished lines that stay as they are and a tail that grows.
///
/// SwiftUI lays a `Text` out whole each time its string changes, so one `Text` for a fence costs more with every chunk.
/// A block equal to what it was is not laid out again: a chunk changes only the tail, which holds fewer than
/// `linesPerBlock` finished lines and the line being written. The iPhone and iPad draw a fence this way while it is
/// written; the Mac changes the end of its field instead.
struct SHFenceBlocks {
    struct Block: Equatable, Identifiable {
        /// Block k holds lines k * linesPerBlock ..< (k + 1) * linesPerBlock of the fence.
        let id: Int
        /// Its lines apart from the break that ends the last.
        let text: String
    }

    static let linesPerBlock = 32

    private(set) var frozen: [Block] = []
    /// The text after the last block: the lines not yet a block, and the line being written.
    private(set) var tail = ""
    /// The code these were cut from, and where in its UTF-8 the tail begins.
    private var source = ""
    private var tailStart = 0
    private let linesPerBlock: Int

    init(linesPerBlock: Int = Self.linesPerBlock) {
        precondition(linesPerBlock > 0)
        self.linesPerBlock = linesPerBlock
    }

    /// Cuts `code`. Code that kept what the blocks hold and added to its end costs only the lines it added;
    /// anything else starts the blocks over.
    mutating func update(to code: String) {
        var text = code
        text.withUTF8 { bytes in
            if !keeps(bytes) {
                frozen = []
                tailStart = 0
            }
            var start = tailStart
            while let end = Self.end(ofLines: linesPerBlock, in: bytes, from: start) {
                // CRLF is one break, which a block must not split.
                let stop = end > start && bytes[end - 1] == Self.carriageReturn ? end - 1 : end
                frozen.append(Block(id: frozen.count, text: String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<stop]), as: UTF8.self)))
                start = end + 1
            }
            tailStart = start
            tail = String(decoding: UnsafeBufferPointer(rebasing: bytes[start...]), as: UTF8.self)
        }
        source = code
    }

    private static let newline: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    /// Whether the blocks are the start of `bytes`, so they can stay.
    private func keeps(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard tailStart <= bytes.count else { return false }
        guard tailStart > 0 else { return true }
        var old = source
        return old.withUTF8 { memcmp($0.baseAddress, bytes.baseAddress, tailStart) == 0 }
    }

    /// The index of the break that ends the `count`th line from `start`, nil when fewer lines than that have ended.
    private static func end(ofLines count: Int, in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        var at = start
        var end = start
        for _ in 0..<count {
            guard at < bytes.count, let hit = memchr(base + at, Int32(newline), bytes.count - at) else { return nil }
            end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            at = end + 1
        }
        return end
    }

    /// Holds the blocks of the fence a view draws, so a body that draws the same fence again, or the fence a chunk longer,
    /// cuts only the lines that are new. Reading it changes nothing a view observes.
    final class Cache {
        private var held = SHFenceBlocks()

        func blocks(for code: String) -> SHFenceBlocks {
            held.update(to: code)
            return held
        }
    }
}

/// A fence being written, drawn block by block: each block is equal to what it was unless its lines changed, so a chunk
/// lays out only the tail. Blocks stack a line's leading apart, as the lines of one `Text` sit. Selecting text stops at a
/// block's edge until the fence is done, when it is one `Text` again.
struct SHFenceBlocksView: View {
    let blocks: SHFenceBlocks
    let lineSpacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(blocks.frozen) { SHFenceLines(text: $0.text).equatable() }
            // A line break at the very end shows a line, as it does in one `Text`; an empty `Text` is shorter than a line.
            SHFenceLines(text: blocks.tail.isEmpty && !blocks.frozen.isEmpty ? " " : blocks.tail).equatable()
        }
    }
}

/// The lines of one block.
struct SHFenceLines: View, Equatable {
    let text: String

    var body: some View {
        let _ = SHRenderProbe.add("code.laidOutUnits", text.utf16.count)
        Text(text)
    }
}

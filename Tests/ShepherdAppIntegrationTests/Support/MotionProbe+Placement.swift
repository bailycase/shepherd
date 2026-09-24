import AppKit

extension MotionRecording.Frame {
    /// The columns where this frame clearly draws over pixels that `before` and `settled` both
    /// leave empty (near the settled frame's color at `empty`): content caught away from both
    /// where it starts and where it rests. A cross-fade never draws there, since every layer is
    /// empty at such a pixel; a nudge, a slide, or a pop does. The gap between "empty" (within
    /// `emptyTolerance`, 0–255 per channel) and "drawn" (at least `drawnThreshold` away) keeps
    /// anti-aliased edges from counting; lower both for a faint fill.
    func columnsAway(from before: Self, _ settled: Self, empty: (x: Int, y: Int), emptyTolerance: Int = 16,
                     drawnThreshold: Int = 48) -> [Int] {
        guard let frame = bitmap.bitmapData, let start = before.bitmap.bitmapData, let end = settled.bitmap.bitmapData,
              before.bitmap.bytesPerRow == bitmap.bytesPerRow, settled.bitmap.bytesPerRow == bitmap.bytesPerRow else { return [] }
        let stride = bitmap.bitsPerPixel / 8
        let reference = empty.y * bitmap.bytesPerRow + empty.x * stride
        func distance(_ data: UnsafeMutablePointer<UInt8>, _ offset: Int) -> Int {
            (0..<3).map { abs(Int(data[offset + $0]) - Int(end[reference + $0])) }.max() ?? 0
        }
        return (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { y in
                let offset = y * bitmap.bytesPerRow + x * stride
                return distance(start, offset) <= emptyTolerance && distance(end, offset) <= emptyTolerance
                    && distance(frame, offset) >= drawnThreshold
            }
        }
    }

    /// Whether this frame draws `rows` exactly as `other` does.
    func matches(_ other: Self, inRows rows: ClosedRange<Int>) -> Bool {
        guard let a = bitmap.bitmapData, let b = other.bitmap.bitmapData, bitmap.bytesPerRow == other.bitmap.bytesPerRow,
              rows.lowerBound >= 0, rows.upperBound < min(bitmap.pixelsHigh, other.bitmap.pixelsHigh) else { return false }
        let start = rows.lowerBound * bitmap.bytesPerRow
        return memcmp(a + start, b + start, rows.count * bitmap.bytesPerRow) == 0
    }

    /// The runs of rows, from the top, that draw at least `drawnThreshold` away from the color at
    /// `empty` in any column: in a column through stacked cards, their lines and content.
    func drawnRuns(over empty: (x: Int, y: Int), drawnThreshold: Int = 6) -> [ClosedRange<Int>] {
        guard let data = bitmap.bitmapData else { return [] }
        let stride = bitmap.bitsPerPixel / 8
        let reference = empty.y * bitmap.bytesPerRow + empty.x * stride
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0...bitmap.pixelsHigh {
            let drawn = y < bitmap.pixelsHigh && (0..<bitmap.pixelsWide).contains { x in
                let offset = y * bitmap.bytesPerRow + x * stride
                return (0..<3).contains { abs(Int(data[offset + $0]) - Int(data[reference + $0])) >= drawnThreshold }
            }
            if drawn, start == nil { start = y }
            if !drawn, let first = start {
                runs.append(first...(y - 1))
                start = nil
            }
        }
        return runs
    }

    /// The first column, from the left, drawing at least `drawnThreshold` away from the color at
    /// `empty`.
    func firstColumn(drawingOver empty: (x: Int, y: Int), drawnThreshold: Int = 48) -> Int? {
        guard let data = bitmap.bitmapData else { return nil }
        let stride = bitmap.bitsPerPixel / 8
        let reference = empty.y * bitmap.bytesPerRow + empty.x * stride
        return (0..<bitmap.pixelsWide).first { x in
            (0..<bitmap.pixelsHigh).contains { y in
                let offset = y * bitmap.bytesPerRow + x * stride
                return (0..<3).contains { abs(Int(data[offset + $0]) - Int(data[reference + $0])) >= drawnThreshold }
            }
        }
    }
}

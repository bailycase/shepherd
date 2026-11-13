import Foundation
import SwiftUI

/// The syntax colors of a fence a reply is still writing: runs of its text (UTF-16 units) in a
/// color, changed only from where the colors last moved to the end, so a view redraws that part and
/// not the whole fence. `revision` counts the changes; `changedFrom` is where the last one began.
public struct SHCodeColors: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var range: Range<Int>
        public var color: Color

        public init(range: Range<Int>, color: Color) {
            self.range = range
            self.color = color
        }
    }

    /// In order of position, none overlapping.
    public private(set) var spans: [Span] = []
    public private(set) var revision = 0
    public private(set) var changedFrom = 0
    /// Tells apart the colors of two fences whose revisions happen to match.
    let lineage = UUID()

    public init() {}

    /// Replaces the colors from `location` on with `spans`, the colors of the text from there.
    public mutating func recolor(from location: Int, with spans: [Span]) {
        var keep = firstIndex(endingAfter: location)
        if keep < self.spans.count, self.spans[keep].range.lowerBound < location {
            self.spans[keep].range = self.spans[keep].range.lowerBound..<location
            keep += 1
        }
        self.spans.removeSubrange(keep...)
        self.spans += spans
        revision += 1
        changedFrom = location
    }

    /// The spans that reach past `location`.
    func spans(from location: Int) -> ArraySlice<Span> {
        spans[firstIndex(endingAfter: location)...]
    }

    /// The first span ending after `location`, by bisection.
    private func firstIndex(endingAfter location: Int) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].range.upperBound > location { high = middle } else { low = middle + 1 }
        }
        return low
    }

    public static func == (lhs: SHCodeColors, rhs: SHCodeColors) -> Bool {
        lhs.lineage == rhs.lineage && lhs.revision == rhs.revision
    }
}

import Foundation

/// How a board leaves as PDF (print.md): a fixed page at its frame's size, or running content
/// the export paginates onto paper.
public enum DesignPrint: Hashable, Sendable {
    /// One page at the board's frame (`print` absent or `"fixed"`).
    case fixed
    /// Running content cut onto `paper` (`"print": "flow"`).
    case flow(Paper)

    /// Paper a flow document runs onto, in CSS px at 96 px/in, portrait.
    public enum Paper: String, Hashable, Sendable {
        case letter, a4

        public var size: CGSize {
            switch self {
            case .letter: return CGSize(width: 816, height: 1056)
            case .a4: return CGSize(width: 794, height: 1123)
            }
        }
    }

    /// A board's print mode, from its canvas entry's `print` and `paper` (Letter unless `a4`).
    public static func of(_ board: DesignIndex.Board) -> DesignPrint {
        guard board.extra["print"]?.stringValue?.lowercased() == "flow" else { return .fixed }
        return .flow(board.extra["paper"]?.stringValue?.lowercased() == "a4" ? .a4 : .letter)
    }

    /// A flow document is cut into at most this many pages.
    public static let maxPages = 100

    /// What the export adds below each cut and above the next page's content: 5% of a page.
    public static func gap(pageHeight: Double) -> Double {
        (pageHeight * 0.05).rounded()
    }

    /// One page of a flow document: the content from `start` to `end` (CSS px down the
    /// document), drawn `top` down the page.
    public struct Slice: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var top: Double

        public init(start: Double, end: Double, top: Double) {
            self.start = start
            self.end = end
            self.top = top
        }

        public var height: Double { end - start }
    }

    /// Where a flow document breaks: each page holds what fits between its gaps, cut between text
    /// `lines` and never through a `block` (an image or an SVG) that fits a page; a block taller
    /// than a page is cut where the page ends. Ranges are CSS px down the document.
    public static func pages(contentHeight: Double, pageHeight: Double, lines: [ClosedRange<Double>] = [],
                             blocks: [ClosedRange<Double>] = []) -> [Slice] {
        let height = max(0, contentHeight.isFinite ? contentHeight : 0)
        let gap = gap(pageHeight: pageHeight)
        guard height > 0, pageHeight > 2 * gap else { return [Slice(start: 0, end: height, top: 0)] }
        var slices: [Slice] = []
        var start = 0.0
        while start < height, slices.count < maxPages {
            let top = slices.isEmpty ? 0 : gap
            let capacity = pageHeight - top - gap
            let limit = start + capacity
            if limit >= height {
                slices.append(Slice(start: start, end: height, top: top))
                break
            }
            let keep = lines + blocks.filter { $0.upperBound - $0.lowerBound <= capacity }
            var cut = limit
            var moved = true
            while moved {
                moved = false
                for range in keep where range.lowerBound > start && range.lowerBound < cut && range.upperBound > cut {
                    cut = range.lowerBound
                    moved = true
                }
            }
            if cut <= start { cut = limit }
            slices.append(Slice(start: start, end: cut, top: top))
            start = cut
        }
        return slices
    }
}

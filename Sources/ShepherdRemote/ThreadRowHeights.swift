import Foundation

/// Slot heights for one column width. Offsets are relative to the start of the history stack.
public struct ThreadRowHeights: Sendable {
    public struct Row: Sendable, Equatable {
        public let id: String
        public let estimate: CGFloat

        public init(id: String, estimate: CGFloat) {
            self.id = id
            self.estimate = estimate
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var width: CGFloat?
    public private(set) var spacing: CGFloat = 0
    private var heights: [String: CGFloat] = [:]
    private var indices: [String: Int] = [:]
    private var offsets: [CGFloat] = [0]

    public init() {}

    public mutating func replace(_ rows: [Row], spacing: CGFloat) {
        guard self.rows != rows || self.spacing != spacing else { return }
        let oldEstimates = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0.estimate) })
        heights = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard oldEstimates[row.id] == row.estimate, let height = heights[row.id] else { return nil }
            return (row.id, height)
        })
        self.rows = rows
        self.spacing = spacing
        indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        rebuildOffsets()
    }

    public mutating func resetMeasurements(width: CGFloat? = nil) {
        self.width = width
        heights.removeAll(keepingCapacity: true)
        rebuildOffsets()
    }

    public func height(for id: String) -> CGFloat? {
        heights[id] ?? indices[id].map { rows[$0].estimate }
    }

    public func index(for id: String) -> Int? { indices[id] }
    public func offset(at index: Int) -> CGFloat { offsets[index] }
    public var height: CGFloat { rows.isEmpty ? 0 : offsets[rows.count] - spacing }

    /// Apply a native layout's measurements together, returning the signed change above the anchor.
    @discardableResult
    public mutating func measure(_ measured: [String: CGFloat], width: CGFloat, above anchor: Int) -> CGFloat {
        if self.width == nil { self.width = width }
        let old = offsets[anchor]
        var changed = false
        for (id, height) in measured where indices[id] != nil && heights[id] != height {
            heights[id] = height
            changed = true
        }
        if changed { rebuildOffsets() }
        return offsets[anchor] - old
    }

    public func range(for clip: CGRect, viewports: Int) -> Range<Int> {
        let padding = clip.height * CGFloat(viewports)
        let first = boundary(after: clip.minY - padding, trailing: true)
        let end = boundary(after: clip.maxY + padding, trailing: false)
        return first..<max(first, end)
    }

    private func boundary(after y: CGFloat, trailing: Bool) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            let edge = trailing ? offsets[middle + 1] : offsets[middle]
            if trailing ? edge <= y : edge < y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private mutating func rebuildOffsets() {
        offsets = [0]
        offsets.reserveCapacity(rows.count + 1)
        for row in rows { offsets.append(offsets.last! + (heights[row.id] ?? row.estimate) + spacing) }
    }
}

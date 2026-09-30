public enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct LeafPane: Codable, Hashable, Sendable {
    public var id: PaneID
    /// In-process session rendered in this pane; nil until one is bound.
    public var sessionID: SessionID?
    public var cwd: String
    public var agentID: AgentID?
    /// Marks a native diff-review pane. Review panes are session-scoped UI and
    /// are purged at startup; old state files decode nil.
    public var isReview: Bool?
    /// A terminal tab's name, set by Rename tab on the tab's first pane; nil names the tab after
    /// what it runs. Old state files decode nil.
    public var title: String?

    public init(
        id: PaneID = PaneID(),
        sessionID: SessionID? = nil,
        cwd: String,
        agentID: AgentID? = nil,
        isReview: Bool? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.agentID = agentID
        self.isReview = isReview
        self.title = title
    }
}

/// Binary split tree. The handoff's `.split(axis, ratio, [PaneNode])` is realized as a
/// two-child split, since a single ratio only defines a binary division.
/// `ratio` is the fraction of the axis given to `first` (0 < ratio < 1).
public indirect enum PaneNode: Hashable, Sendable {
    case leaf(LeafPane)
    case split(axis: SplitAxis, ratio: Double, first: PaneNode, second: PaneNode)
}

public extension PaneNode {
    var leaves: [LeafPane] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(_, _, let first, let second):
            return first.leaves + second.leaves
        }
    }

    var firstLeaf: LeafPane {
        switch self {
        case .leaf(let pane): return pane
        case .split(_, _, let first, _): return first.firstLeaf
        }
    }

    func contains(_ id: PaneID) -> Bool {
        leaves.contains { $0.id == id }
    }

    func leaf(withID id: PaneID) -> LeafPane? {
        leaves.first { $0.id == id }
    }

    /// The layout's terminals when `thread` is the agent's own pane: the layout's largest
    /// subtrees that hold no thread, oldest first, each read left to right. The shallowest
    /// subtree is the oldest, since a terminal opened beside the thread lands closest to it.
    /// Empty when the layout does not hold `thread`.
    func terminals(besideThread thread: PaneID) -> [LeafPane] {
        guard contains(thread) else { return [] }
        var terminals: [LeafPane] = []
        var node = self
        while case .split(_, _, let first, let second) = node {
            if first.contains(thread) {
                terminals += second.leaves
                node = first
            } else {
                terminals += first.leaves
                node = second
            }
        }
        return terminals
    }

    /// Whether the layout has a subtree of several terminals beside `thread`, as older builds
    /// made with Split right and Split down.
    func hasSplitTerminals(besideThread thread: PaneID) -> Bool {
        guard contains(thread) else { return false }
        var node = self
        while case .split(_, _, let first, let second) = node {
            let beside = first.contains(thread) ? second : first
            if case .split = beside { return true }
            node = first.contains(thread) ? first : second
        }
        return false
    }

    /// The layout with every terminal in a tab of its own: what a layout with split terminals
    /// becomes when loaded. Each terminal keeps its session, folder and title, the order the
    /// tabs had is kept, and the thread stays where the tabs hang from. A layout that has no
    /// split terminals, or does not hold `thread`, is returned as it is.
    func flatteningTerminals(besideThread thread: PaneID) -> PaneNode {
        guard hasSplitTerminals(besideThread: thread), let own = leaf(withID: thread) else { return self }
        var layout = PaneNode.leaf(own)
        for terminal in terminals(besideThread: thread).reversed() {
            layout = .split(axis: .horizontal, ratio: 0.5, first: layout, second: .leaf(terminal))
        }
        return layout
    }

    /// Replace the leaf `paneID` with a split of it and `newPane`. Returns nil when the pane is absent.
    func splitting(pane paneID: PaneID, axis: SplitAxis, newPane: LeafPane, ratio: Double = 0.5) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return nil }
            return .split(axis: axis, ratio: ratio, first: .leaf(pane), second: .leaf(newPane))
        case .split(let axis0, let ratio0, let first, let second):
            if let replaced = first.splitting(pane: paneID, axis: axis, newPane: newPane, ratio: ratio) {
                return .split(axis: axis0, ratio: ratio0, first: replaced, second: second)
            }
            if let replaced = second.splitting(pane: paneID, axis: axis, newPane: newPane, ratio: ratio) {
                return .split(axis: axis0, ratio: ratio0, first: first, second: replaced)
            }
            return nil
        }
    }

    /// Remove the leaf `paneID`, collapsing its parent split into the sibling.
    /// Returns nil when removing the only remaining leaf.
    func closing(pane paneID: PaneID) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self
        case .split(let axis, let ratio, let first, let second):
            if first.contains(paneID) {
                guard let newFirst = first.closing(pane: paneID) else { return second }
                return .split(axis: axis, ratio: ratio, first: newFirst, second: second)
            }
            if second.contains(paneID) {
                guard let newSecond = second.closing(pane: paneID) else { return first }
                return .split(axis: axis, ratio: ratio, first: first, second: newSecond)
            }
            return self
        }
    }

    /// Apply `transform` to the leaf `paneID`, returning the updated tree.
    func updatingLeaf(_ paneID: PaneID, _ transform: (inout LeafPane) -> Void) -> PaneNode {
        switch self {
        case .leaf(var pane):
            guard pane.id == paneID else { return self }
            transform(&pane)
            return .leaf(pane)
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: first.updatingLeaf(paneID, transform),
                second: second.updatingLeaf(paneID, transform)
            )
        }
    }

    /// Set the ratio of the deepest split containing `paneID`.
    func updatingRatio(ofSplitContaining paneID: PaneID, to ratio: Double) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let oldRatio, let first, let second):
            if first.contains(paneID) {
                let updated = first.updatingRatio(ofSplitContaining: paneID, to: ratio)
                if updated != first {
                    return .split(axis: axis, ratio: oldRatio, first: updated, second: second)
                }
                return .split(axis: axis, ratio: ratio, first: first, second: second)
            }
            if second.contains(paneID) {
                let updated = second.updatingRatio(ofSplitContaining: paneID, to: ratio)
                if updated != second {
                    return .split(axis: axis, ratio: oldRatio, first: first, second: updated)
                }
                return .split(axis: axis, ratio: ratio, first: first, second: second)
            }
            return self
        }
    }
}

extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, pane, axis, ratio, first, second
    }

    private enum NodeType: String, Codable {
        case leaf, split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .leaf:
            self = .leaf(try container.decode(LeafPane.self, forKey: .pane))
        case .split:
            self = .split(
                axis: try container.decode(SplitAxis.self, forKey: .axis),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(PaneNode.self, forKey: .first),
                second: try container.decode(PaneNode.self, forKey: .second)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let axis, let ratio, let first, let second):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}


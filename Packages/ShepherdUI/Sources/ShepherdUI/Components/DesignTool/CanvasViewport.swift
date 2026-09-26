import SwiftUI

/// Where the canvas looks: the screen position of the canvas's origin and the zoom. Boards are
/// laid out in canvas points (a board's CSS pixels); the screen shows them `zoom` times as large.
public struct NWCanvasViewport: Equatable, Sendable {
    public var offset: CGPoint
    public var zoom: CGFloat

    /// The boards draw no limits; these only keep the arithmetic sane.
    public static let zoomRange: ClosedRange<CGFloat> = 0.05...4

    public init(offset: CGPoint = .zero, zoom: CGFloat = 1) {
        self.offset = offset
        self.zoom = Self.clamp(zoom)
    }

    public static func clamp(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// A canvas point on screen.
    public func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + point.x * zoom, y: offset.y + point.y * zoom)
    }

    /// The canvas point under a screen point.
    public func canvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / zoom, y: (point.y - offset.y) / zoom)
    }

    public func screen(_ rect: CGRect) -> CGRect {
        CGRect(origin: screen(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    /// The part of the canvas a view of `size` shows.
    public func visibleRect(in size: CGSize) -> CGRect {
        CGRect(origin: canvas(.zero), size: CGSize(width: size.width / zoom, height: size.height / zoom))
    }

    public mutating func pan(by delta: CGSize) {
        offset.x += delta.width
        offset.y += delta.height
    }

    /// Zooms by `factor`, keeping the canvas point under `anchor` (a screen point) where it is.
    public mutating func zoom(by factor: CGFloat, about anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let fixed = canvas(anchor)
        zoom = Self.clamp(zoom * factor)
        offset = CGPoint(x: anchor.x - fixed.x * zoom, y: anchor.y - fixed.y * zoom)
    }

    /// "42%".
    public var percent: String { "\(Int((zoom * 100).rounded()))%" }

    /// The boards' bounds fitted into a view of `size`, never larger than 100%: their
    /// top-leading corner 44pt in, and the top row's labels 52pt down (its frames 76pt down), so
    /// the board actions have room above those labels (DZCanvas). 52pt stays free below.
    public static func fitting(_ bounds: CGRect, in size: CGSize) -> NWCanvasViewport {
        let M = NWDesignMetrics.self
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
            return NWCanvasViewport(offset: CGPoint(x: M.fitLeading, y: M.fitFrameTop), zoom: 1)
        }
        let room = CGSize(width: size.width - M.fitLeading * 2, height: size.height - M.fitFrameTop - M.fitTop)
        let zoom = clamp(min(1, max(room.width, 1) / bounds.width, max(room.height, 1) / bounds.height))
        return NWCanvasViewport(offset: CGPoint(x: M.fitLeading - bounds.minX * zoom, y: M.fitFrameTop - bounds.minY * zoom), zoom: zoom)
    }
}

/// The canvas toolbar's tools (NWCanvasToolbar): Select picks a board, Comment pins a comment
/// (not built: drawn disabled), Pan drags the canvas.
public enum NWCanvasTool: String, CaseIterable, Sendable {
    case select, comment, pan

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .comment: "text.bubble"
        case .pan: "hand.raised"
        }
    }

    public var title: String {
        switch self {
        case .select: "Select"
        case .comment: "Comment"
        case .pan: "Pan"
        }
    }
}

/// One board on the canvas as its frame draws it.
public struct NWCanvasBoard: Identifiable, Equatable, Sendable {
    public let id: String
    /// Where it sits, in canvas points.
    public var frame: CGRect
    /// "A · Funnel first".
    public var title: String
    /// "1280 × 800".
    public var size: String
    public var isSelected: Bool
    /// Moves whenever what the frame's slot shows changes (a new snapshot, a live view coming or
    /// going): a frame redraws only when its board does.
    public var content: Int
    /// The room its label has among the boards around it (`NWLabelRoom.rooms`).
    public var labelRoom: NWLabelRoom

    public init(id: String, frame: CGRect, title: String, size: String, isSelected: Bool = false, content: Int = 0,
                labelRoom: NWLabelRoom = .open) {
        self.id = id
        self.frame = frame
        self.title = title
        self.size = size
        self.isSelected = isSelected
        self.content = content
        self.labelRoom = labelRoom
    }

    /// "1280 × 800", the board's CSS pixel size.
    public static func sizeLabel(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}

/// The room a board's label has, in canvas points, so that at a low zoom (rows 120 apart are
/// about 20pt at 17%) no label lies over another board: how far up the nearest board above it is,
/// and how far along its top edge the next board in its row starts.
public struct NWLabelRoom: Equatable, Sendable {
    /// Clear canvas points between the board's top and the nearest board above its label; nil
    /// when nothing is above.
    public var above: CGFloat?
    /// Canvas points from the board's leading edge to the next board beside it; nil when none.
    public var along: CGFloat?

    public static let open = NWLabelRoom()

    public init(above: CGFloat? = nil, along: CGFloat? = nil) {
        self.above = above
        self.along = along
    }

    /// The label at `zoom` over a board `width` points wide on screen: whether it is drawn, how
    /// wide it runs, and its gap to the frame. It keeps its 8pt gap where the room allows, moves
    /// down toward the frame where it doesn't, and isn't drawn where not even a 2pt gap fits.
    public func layout(width: CGFloat, zoom: CGFloat) -> (shown: Bool, width: CGFloat, gap: CGFloat) {
        var labelWidth = Swift.max(width, NWDesignMetrics.labelMinWidth)
        if let along { labelWidth = Swift.min(labelWidth, along * zoom - NWDesignMetrics.labelSpacing) }
        guard let above else { return (labelWidth > 0, labelWidth, NWDesignMetrics.labelGap) }
        let room = above * zoom - NWDesignMetrics.labelHeight
        guard room >= NWDesignMetrics.labelMinGap, labelWidth > 0 else { return (false, Swift.max(labelWidth, 0), NWDesignMetrics.labelGap) }
        return (true, labelWidth, Swift.min(NWDesignMetrics.labelGap, room))
    }

    /// Each board's room among `frames` (canvas points, by id). `along` is the nearest board that
    /// starts further along and overlaps the board's height; `above`, the nearest board wholly
    /// above that overlaps the stretch the label can run over.
    public static func rooms(_ frames: [String: CGRect]) -> [String: NWLabelRoom] {
        let all = Array(frames)
        var rooms: [String: NWLabelRoom] = [:]
        for (id, frame) in all {
            var along: CGFloat?
            for (other, rect) in all where other != id && rect.minX > frame.minX
                && rect.minY < frame.maxY && rect.maxY > frame.minY {
                along = Swift.min(along ?? .infinity, rect.minX - frame.minX)
            }
            let reach = frame.minX + Swift.max(frame.width, along ?? frame.width)
            var above: CGFloat?
            for (other, rect) in all where other != id && rect.maxY <= frame.minY
                && rect.minX < reach && rect.maxX > frame.minX {
                above = Swift.min(above ?? .infinity, frame.minY - rect.maxY)
            }
            rooms[id] = NWLabelRoom(above: above, along: along)
        }
        return rooms
    }
}

/// A board element the canvas rings: the selection, or the one under the pointer.
public struct NWCanvasElement: Identifiable, Equatable, Sendable {
    /// Its id (`File.dc.html#tid:path`).
    public let id: String
    /// The board it is on (`NWCanvasBoard.id`).
    public var board: String
    /// Where it is drawn, in the board's own points from its top left.
    public var rect: CGRect
    /// "card · Checkout funnel", drawn over a selected element's top-leading corner; nil draws none.
    public var tag: String?

    public init(id: String, board: String, rect: CGRect, tag: String? = nil) {
        self.id = id
        self.board = board
        self.rect = rect
        self.tag = tag
    }
}

/// A comment's pin on the canvas (`NWCommentPin`), on its element's top-trailing corner.
public struct NWCanvasPin: Identifiable, Equatable, Sendable {
    /// The comment's id.
    public let id: String
    /// The board it is on (`NWCanvasBoard.id`).
    public var board: String
    /// Where its element is drawn, in the board's own points.
    public var rect: CGRect
    public var number: Int

    public init(id: String, board: String, rect: CGRect, number: Int) {
        self.id = id
        self.board = board
        self.rect = rect
        self.number = number
    }
}

/// The board actions over one board (`NWBoardActions`): which board, and what each does.
public struct NWCanvasActions {
    /// The board they float over (`NWCanvasBoard.id`).
    public var board: String
    public var actions: NWBoardActions.Actions

    public init(board: String, actions: NWBoardActions.Actions) {
        self.board = board
        self.actions = actions
    }
}

/// A board being dragged to a new place on the canvas.
public struct NWBoardMove: Equatable, Sendable {
    /// The board (`NWCanvasBoard.id`).
    public var board: String
    /// How far it has moved since the drag began, in canvas points.
    public var offset: CGSize
    /// The drag has ended: this is where the board stays.
    public var ended: Bool

    public init(board: String, offset: CGSize, ended: Bool) {
        self.board = board
        self.offset = offset
        self.ended = ended
    }
}

/// Where a click or the pointer landed on the canvas.
public struct NWCanvasPick: Equatable, Sendable {
    /// The board under it, front-most first; nil over the empty canvas.
    public var board: String?
    /// The point on that board in its own points; nil when it landed on the board's label.
    public var point: CGPoint?
    /// Shift was held: the pick adds to the selection, or takes itself out of it.
    public var extending: Bool

    public init(board: String? = nil, point: CGPoint? = nil, extending: Bool = false) {
        self.board = board
        self.point = point
        self.extending = extending
    }
}

extension Array where Element == NWCanvasBoard {
    /// What is under a screen point: a board (the front-most), and where on it, or its label.
    public func pick(at point: CGPoint, viewport: NWCanvasViewport, extending: Bool = false) -> NWCanvasPick {
        if let board = board(at: point, viewport: viewport) {
            let origin = viewport.screen(board.frame.origin)
            return NWCanvasPick(board: board.id, point: CGPoint(x: (point.x - origin.x) / viewport.zoom, y: (point.y - origin.y) / viewport.zoom),
                                extending: extending)
        }
        for board in reversed() {
            let frame = viewport.screen(board.frame)
            let label = board.labelRoom.layout(width: frame.width, zoom: viewport.zoom)
            guard label.shown else { continue }
            let rect = CGRect(x: frame.minX, y: frame.minY - label.gap - NWDesignMetrics.labelHeight,
                              width: label.width, height: NWDesignMetrics.labelHeight)
            if rect.contains(point) { return NWCanvasPick(board: board.id, extending: extending) }
        }
        return NWCanvasPick(extending: extending)
    }

    /// The boards a view of `size` shows at `viewport`, with room for their labels, back to
    /// front as given.
    public func visible(in viewport: NWCanvasViewport, size: CGSize) -> [NWCanvasBoard] {
        let bounds = CGRect(origin: .zero, size: size)
        return filter { board in
            var rect = viewport.screen(board.frame)
            rect.origin.y -= NWDesignMetrics.labelHeight + NWDesignMetrics.labelGap
            rect.size.height += NWDesignMetrics.labelHeight + NWDesignMetrics.labelGap
            return rect.insetBy(dx: -NWDesignMetrics.ringWidth, dy: -NWDesignMetrics.ringWidth).intersects(bounds)
        }
    }

    /// The front-most board under a screen point.
    public func board(at point: CGPoint, viewport: NWCanvasViewport) -> NWCanvasBoard? {
        let canvasPoint = viewport.canvas(point)
        return last { $0.frame.contains(canvasPoint) }
    }

    /// Every board's frame together.
    public var bounds: CGRect {
        reduce(CGRect.null) { $0.union($1.frame) }
    }
}

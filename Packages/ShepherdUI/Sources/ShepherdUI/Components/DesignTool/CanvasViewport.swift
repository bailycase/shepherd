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

    /// The boards' bounds fitted into a view of `size`: their top-leading corner 44pt in and
    /// 52pt down, never larger than 100%.
    public static func fitting(_ bounds: CGRect, in size: CGSize) -> NWCanvasViewport {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
            return NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading, y: NWDesignMetrics.fitTop), zoom: 1)
        }
        let room = CGSize(width: size.width - NWDesignMetrics.fitLeading * 2, height: size.height - NWDesignMetrics.fitTop * 2)
        let zoom = clamp(min(1, max(room.width, 1) / bounds.width, max(room.height, 1) / bounds.height))
        return NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading - bounds.minX * zoom,
                                                y: NWDesignMetrics.fitTop - bounds.minY * zoom), zoom: zoom)
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

    public init(id: String, frame: CGRect, title: String, size: String, isSelected: Bool = false, content: Int = 0) {
        self.id = id
        self.frame = frame
        self.title = title
        self.size = size
        self.isSelected = isSelected
        self.content = content
    }

    /// "1280 × 800", the board's CSS pixel size.
    public static func sizeLabel(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}

extension Array where Element == NWCanvasBoard {
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

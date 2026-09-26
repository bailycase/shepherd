import SwiftUI

/// The board actions (NWBoardActions; NWDesignTool, DZCanvas), floating over the selected board:
/// Comment (`text.bubble`), Tweak (`slider.horizontal.3`), Variations (`square.grid.2x2`),
/// Duplicate (`doc.on.doc`), and ••• (a circle). A `bgRaised` bar with the popover's line and
/// shadow; each item a 13pt glyph in `textSecondary` beside its label in `textPrimary`.
///
/// `.regular` is NWDesignTool's specimen; `.compact` is how DZCanvas draws it over a board.
/// ••• holds Play for an interactive board, and is disabled otherwise: what else it lists is not
/// drawn.
public struct NWBoardActions: View {
    public enum Size: Sendable {
        case regular
        case compact
    }

    public struct Actions {
        public var comment: () -> Void
        public var tweak: () -> Void
        public var variations: () -> Void
        public var duplicate: () -> Void
        /// Play, for an interactive board; nil for a static one.
        public var play: (() -> Void)?

        public init(comment: @escaping () -> Void, tweak: @escaping () -> Void, variations: @escaping () -> Void,
                    duplicate: @escaping () -> Void, play: (() -> Void)? = nil) {
            self.comment = comment
            self.tweak = tweak
            self.variations = variations
            self.duplicate = duplicate
            self.play = play
        }
    }

    let size: Size
    let actions: Actions

    public init(size: Size = .regular, actions: Actions) {
        self.size = size
        self.actions = actions
    }

    public var body: some View {
        let M = NWDesignMetrics.self
        let compact = size == .compact
        let itemHeight = compact ? M.compactActionItemHeight : M.actionItemHeight
        HStack(spacing: M.actionsSpacing) {
            NWBoardAction("Comment", symbol: "text.bubble", size: size, action: actions.comment)
            NWBoardAction("Tweak", symbol: "slider.horizontal.3", size: size, action: actions.tweak)
            NWBoardAction("Variations", symbol: "square.grid.2x2", size: size, action: actions.variations)
            NWBoardAction("Duplicate", symbol: "doc.on.doc", size: size, action: actions.duplicate)
            Menu {
                if let play = actions.play { Button("Play", systemImage: "play.fill", action: play) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.nwSans(M.moreGlyph))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.nwIcon(size: itemHeight))
            .fixedSize()
            .disabled(actions.play == nil)
            .accessibilityLabel("More")
        }
        .padding(M.actionsPadding)
        .frame(height: compact ? M.compactActionsHeight : nil)
        .nwPopover(radius: compact ? M.compactActionsRadius : M.actionsRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Board actions")
    }
}

/// One of the board actions: its glyph and label, the hover fill on `bgHover`.
private struct NWBoardAction: View {
    let title: String
    let symbol: String
    let size: NWBoardActions.Size
    let action: () -> Void

    init(_ title: String, symbol: String, size: NWBoardActions.Size, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.size = size
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        let M = NWDesignMetrics.self
        let compact = size == .compact
        let radius = compact ? M.compactActionItemRadius : M.actionItemRadius
        Button(action: action) {
            HStack(spacing: M.actionItemGap) {
                Image(systemName: symbol)
                    .font(.nwSans(M.actionGlyph))
                    .foregroundStyle(Color.nw.textSecondary)
                Text(title)
                    .font(.nwSans(compact ? M.compactActionTextSize : M.actionTextSize))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? M.compactActionItemPadding : M.actionItemPadding)
            .frame(height: compact ? M.compactActionItemHeight : M.actionItemHeight)
            .background(hovering ? Color.nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: radius))
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .help(title)
    }
}

extension NWBoardActions {
    /// Where the bar goes over a board whose frame is `board` on screen: its bottom `actionsGap`
    /// above the board's label strip, its leading edge at the frame's middle (DZCanvas), kept
    /// `inset` inside a canvas of `canvas` along its width and 4pt from its top. Nil when the
    /// board is off screen.
    public static func origin(over board: CGRect, bar: CGSize, canvas: CGSize,
                              inset: CGFloat = NWDesignMetrics.toolbarInset) -> CGPoint? {
        guard board.intersects(CGRect(origin: .zero, size: canvas)) else { return nil }
        let lift = NWDesignMetrics.labelHeight + NWDesignMetrics.labelGap + NWDesignMetrics.actionsGap
        let x = min(max(board.midX, inset), max(inset, canvas.width - bar.width - inset))
        // Where the board sits too near the top for it (a fitted canvas), as high as it can go.
        let y = max(board.minY - lift - bar.height, NW.Space.xs)
        return CGPoint(x: x, y: y)
    }
}

/// "Ask for another direction" (DZCanvas): a dashed 300×190 tile after the last board, a `plus`
/// over the words. It asks the design agent for one more direction.
public struct NWDirectionTile: View {
    let action: () -> Void
    @State private var hovering = false

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        let M = NWDesignMetrics.self
        let shape = RoundedRectangle(cornerRadius: M.directionTileRadius)
        Button(action: action) {
            VStack(spacing: M.directionTileSpacing) {
                Image(systemName: "plus")
                    .font(.nwSans(M.directionTileGlyph))
                Text("Ask for another direction")
                    .font(.nwSans(M.directionTileTextSize))
            }
            .foregroundStyle(hovering ? Color.nw.textSecondary : Color.nw.textTertiary)
            .frame(width: M.directionTileSize.width, height: M.directionTileSize.height)
            .nwBorder(Color.nw.lineStrong, in: shape, dash: M.directionTileDash)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
    }

    /// Where the tile goes after the last board, whose frame is `board` on screen.
    public static func origin(after board: CGRect) -> CGPoint {
        CGPoint(x: board.maxX + NWDesignMetrics.directionTileGap, y: board.minY)
    }
}

/// A note on the canvas, read-only: a title (`title1`) or a sticky, at its canvas position.
public struct NWCanvasNote: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case title
        case sticky
    }

    public let id: String
    public var kind: Kind
    /// Its top-leading corner, in canvas points.
    public var origin: CGPoint
    /// How wide it may run, in canvas points; nil for its kind's own width.
    public var width: CGFloat?
    public var text: String

    public init(id: String, kind: Kind, origin: CGPoint, width: CGFloat? = nil, text: String) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.width = width
        self.text = text
    }

    /// Roughly where it lies on the canvas (its width, and a line or two of height), to find the
    /// notes on screen.
    public var bounds: CGRect {
        let M = NWDesignMetrics.self
        switch kind {
        case .title:
            return CGRect(x: origin.x, y: origin.y, width: width ?? M.titleNoteSize * 20, height: M.titleNoteSize * 3)
        case .sticky:
            return CGRect(x: origin.x, y: origin.y, width: width ?? M.stickyWidth, height: M.stickyWidth)
        }
    }
}

/// A note as the canvas draws it at `zoom`: a title's words in `textPrimary` semibold, or a
/// sticky's in a raised card with a line. It takes no events.
struct NWCanvasNoteView: View, Equatable {
    let note: NWCanvasNote
    let zoom: CGFloat

    var body: some View {
        let M = NWDesignMetrics.self
        switch note.kind {
        case .title:
            let words = Text(note.text)
                .font(.nwSans(M.titleNoteSize * zoom, .semibold))
                .foregroundStyle(Color.nw.textPrimary)
            if let width = note.width {
                words
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width * zoom, alignment: .leading)
            } else {
                words.fixedSize()
            }
        case .sticky:
            Text(note.text)
                .font(.nwSans(M.stickyTextSize * zoom))
                .foregroundStyle(Color.nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(M.stickyPadding * zoom)
                .frame(width: (note.width ?? M.stickyWidth) * zoom, alignment: .topLeading)
                .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: M.stickyRadius * zoom))
                .nwBorder(Color.nw.lineStrong, radius: M.stickyRadius * zoom)
        }
    }
}

/// One board shown focused over the canvas (Present, Play): a `scrim` over everything, and the
/// board fitted into the view in its frame. A click on the scrim closes it. The slot draws the
/// board's page, which takes its own events here, so its links work.
public struct NWBoardPresentation<Slot: View>: View {
    let title: String
    let boardSize: CGSize
    let close: () -> Void
    let slot: (CGFloat) -> Slot

    /// `slot` draws the board at the zoom it is given; `title` names it for accessibility.
    public init(title: String, boardSize: CGSize, close: @escaping () -> Void, @ViewBuilder slot: @escaping (CGFloat) -> Slot) {
        self.title = title
        self.boardSize = boardSize
        self.close = close
        self.slot = slot
    }

    public var body: some View {
        GeometryReader { proxy in
            let zoom = Self.zoom(for: boardSize, in: proxy.size)
            ZStack {
                Color.nw.scrim
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Close")
                NWBoardSurface(size: CGSize(width: boardSize.width * zoom, height: boardSize.height * zoom), selected: false) {
                    slot(zoom)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
            }
        }
    }

    /// The board fitted into a view of `size` with the canvas's fitted margins around it, never
    /// larger than 100%.
    public static func zoom(for board: CGSize, in size: CGSize) -> CGFloat {
        let room = CGSize(width: size.width - NWDesignMetrics.fitLeading * 2, height: size.height - NWDesignMetrics.fitTop * 2)
        guard board.width > 0, board.height > 0, room.width > 0, room.height > 0 else { return NWCanvasViewport.zoomRange.lowerBound }
        return NWCanvasViewport.clamp(min(1, room.width / board.width, room.height / board.height))
    }
}

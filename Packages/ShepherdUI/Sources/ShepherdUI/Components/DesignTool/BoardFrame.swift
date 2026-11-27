import SwiftUI

/// A board on the canvas (SHBoardFrame; DZCanvas): its label 24pt above it where the boards
/// around it leave room (the name in 12 semibold, `textPrimary` when selected, else
/// `textSecondary`, then its size in mono 10.5 `textTertiary`), and the board's page at the canvas's zoom in a radius-4 frame with a hairline
/// and a soft drop shadow. A selected board wears a 2pt `running` ring outside the frame.
///
/// The slot draws the board: a live view, or a snapshot. The frame compares its board and zoom
/// alone (`SHCanvasBoard.content` moves when the slot's drawing does), so the canvas panning or
/// another board changing never redraws it.
public struct SHBoardFrame<Slot: View>: View, Equatable {
    let board: SHCanvasBoard
    let zoom: CGFloat
    let slot: Slot

    public init(board: SHCanvasBoard, zoom: CGFloat, @ViewBuilder slot: () -> Slot) {
        self.board = board
        self.zoom = zoom
        self.slot = slot()
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool { a.board == b.board && a.zoom == b.zoom }

    public var body: some View {
        let _ = SHRenderProbe.tick("design.board")
        let size = CGSize(width: board.frame.width * zoom, height: board.frame.height * zoom)
        // A board drawn narrower than its label (a phone at a low zoom) lets it run past, up to
        // the next board; where the row above is closer than the label, it moves down toward
        // the frame, and isn't drawn where it would lie over that row (`SHLabelRoom`).
        let label = board.labelRoom.layout(width: size.width, zoom: zoom)
        VStack(alignment: .leading, spacing: 0) {
            SHBoardLabel(title: board.title, size: board.size, usage: board.usage, selected: board.isSelected)
                .frame(width: label.width, height: SHDesignMetrics.labelHeight, alignment: .leading)
                .padding(.bottom, label.gap)
                .frame(height: SHDesignMetrics.labelHeight + SHDesignMetrics.labelGap, alignment: .bottom)
                .opacity(label.shown ? 1 : 0)
            SHBoardSurface(size: size, selected: board.isSelected) { slot }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(board.title), \(board.size)\(board.usage.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(board.isSelected ? [.isSelected, .isImage] : .isImage)
    }
}

/// A board's label: its name and, 8pt after it, its size, then (for a shared piece other boards
/// import) how many use it, "used in 3 boards", in sans 10.5 `textTertiary`, left out of a label
/// too narrow to hold it beside the name and size.
public struct SHBoardLabel: View {
    let title: String
    let size: String
    let usage: String?
    let selected: Bool

    public init(title: String, size: String, usage: String? = nil, selected: Bool) {
        self.title = title
        self.size = size
        self.usage = usage
        self.selected = selected
    }

    public var body: some View {
        // The size is the first thing a narrow label gives up (a fitted canvas of hundreds of
        // boards), after the usage: the name, cut with an ellipsis, stays.
        ViewThatFits(in: .horizontal) {
            if let usage { row(usage, showingSize: true) }
            row(nil, showingSize: true)
            row(nil, showingSize: false)
        }
    }

    private func row(_ usage: String?, showingSize: Bool) -> some View {
        #if os(macOS)
        // DZCanvas: the name in 12 medium `textPrimary`, its size and use in 12 `textTertiary`.
        let nameFont = Font.shSans(SHDesignChrome.labelTextSize, .medium)
        let nameColor = Color.sh.textPrimary
        let sizeFont = Font.shSans(SHDesignChrome.labelTextSize)
        #else
        let nameFont = Font.shSans(SHDesignMetrics.labelSize, .semibold)
        let nameColor = selected ? Color.sh.textPrimary : Color.sh.textSecondary
        let sizeFont = Font.shMono(SHDesignMetrics.labelSizeTextSize)
        #endif
        return HStack(spacing: SHDesignMetrics.labelSpacing) {
            Text(title)
                .font(nameFont)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if showingSize {
                Text(size)
                    .font(sizeFont)
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let usage {
                Text(usage)
                    .font(.shSans(SHDesignMetrics.labelSizeTextSize))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The board's page in its frame: clipped to radius 12 (the iPad and phone boards') with a hairline, casting the popover's
/// shadow, and ringed while selected. Its fill shows until the slot draws. On the Mac (DZCanvas) it is
/// radius 6 on the cards' `lift`, with a 1.5pt ink ring while selected.
public struct SHBoardSurface<Slot: View>: View {
    let size: CGSize
    let selected: Bool
    let slot: Slot

    public init(size: CGSize, selected: Bool, @ViewBuilder slot: () -> Slot) {
        self.size = size
        self.selected = selected
        self.slot = slot()
    }

    public var body: some View {
        #if os(macOS)
        let radius = SHDesignChrome.boardRadius
        let ring = SHDesignChrome.boardRing
        let shape = RoundedRectangle(cornerRadius: radius)
        slot
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(shape)
            // The lift is cast by a fill with a path set at layout, so a zoom that resizes every board draws no offscreen shadow.
            .shLift(shape)
            .shBorder(Color.sh.lineSubtle, radius: radius)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius + ring)
                        .inset(by: -ring)
                        .strokeBorder(Color.sh.textPrimary, lineWidth: ring)
                        .allowsHitTesting(false)
                }
            }
        #else
        // A fitted canvas of hundreds of boards draws them a few dozen points wide: their corners shrink with them.
        let radius = Swift.min(SHDesignMetrics.frameRadius, Swift.max(SH.Space.xxs, Swift.min(size.width, size.height) / 8))
        let shape = RoundedRectangle(cornerRadius: radius)
        slot
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background { shape.fill(Color.sh.bgRaised).shadow(color: .sh.popoverShadow, radius: SHDesignMetrics.frameShadowRadius, y: SHDesignMetrics.frameShadowY) }
            .clipShape(shape)
            .shBorder(Color.sh.lineSubtle, radius: radius)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius + SHDesignMetrics.ringWidth)
                        .inset(by: -SHDesignMetrics.ringWidth)
                        .strokeBorder(Color.sh.running, lineWidth: SHDesignMetrics.ringWidth)
                        .allowsHitTesting(false)
                }
            }
        #endif
    }
}

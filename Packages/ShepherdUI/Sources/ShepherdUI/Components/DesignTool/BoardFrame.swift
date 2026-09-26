import SwiftUI

/// A board on the canvas (NWBoardFrame; DZCanvas): its label 24pt above it where the boards
/// around it leave room (the name in 12 semibold, `textPrimary` when selected, else
/// `textSecondary`, then its size in mono 10.5 `textTertiary`), and the board's page at the canvas's zoom in a radius-4 frame with a hairline
/// and a soft drop shadow. A selected board wears a 2pt `running` ring outside the frame.
///
/// The slot draws the board: a live view, or a snapshot. The frame compares its board and zoom
/// alone (`NWCanvasBoard.content` moves when the slot's drawing does), so the canvas panning or
/// another board changing never redraws it.
public struct NWBoardFrame<Slot: View>: View, Equatable {
    let board: NWCanvasBoard
    let zoom: CGFloat
    let slot: Slot

    public init(board: NWCanvasBoard, zoom: CGFloat, @ViewBuilder slot: () -> Slot) {
        self.board = board
        self.zoom = zoom
        self.slot = slot()
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool { a.board == b.board && a.zoom == b.zoom }

    public var body: some View {
        let _ = NWRenderProbe.tick("design.board")
        let size = CGSize(width: board.frame.width * zoom, height: board.frame.height * zoom)
        // A board drawn narrower than its label (a phone at a low zoom) lets it run past, up to
        // the next board; where the row above is closer than the label, it moves down toward
        // the frame, and isn't drawn where it would lie over that row (`NWLabelRoom`).
        let label = board.labelRoom.layout(width: size.width, zoom: zoom)
        VStack(alignment: .leading, spacing: 0) {
            NWBoardLabel(title: board.title, size: board.size, selected: board.isSelected)
                .frame(width: label.width, height: NWDesignMetrics.labelHeight, alignment: .leading)
                .padding(.bottom, label.gap)
                .frame(height: NWDesignMetrics.labelHeight + NWDesignMetrics.labelGap, alignment: .bottom)
                .opacity(label.shown ? 1 : 0)
            NWBoardSurface(size: size, selected: board.isSelected) { slot }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(board.title), \(board.size)")
        .accessibilityAddTraits(board.isSelected ? [.isSelected, .isImage] : .isImage)
    }
}

/// A board's label: its name and, 8pt after it, its size.
public struct NWBoardLabel: View {
    let title: String
    let size: String
    let selected: Bool

    public init(title: String, size: String, selected: Bool) {
        self.title = title
        self.size = size
        self.selected = selected
    }

    public var body: some View {
        HStack(spacing: NWDesignMetrics.labelSpacing) {
            Text(title)
                .font(.nwSans(NWDesignMetrics.labelSize, .semibold))
                .foregroundStyle(selected ? Color.nw.textPrimary : Color.nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(size)
                .font(.nwMono(NWDesignMetrics.labelSizeTextSize))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The board's page in its frame: clipped to radius 4 with a hairline, casting the popover's
/// shadow, and ringed while selected. Its fill shows until the slot draws.
public struct NWBoardSurface<Slot: View>: View {
    let size: CGSize
    let selected: Bool
    let slot: Slot

    public init(size: CGSize, selected: Bool, @ViewBuilder slot: () -> Slot) {
        self.size = size
        self.selected = selected
        self.slot = slot()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.frameRadius)
        slot
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background { shape.fill(Color.nw.bgRaised).shadow(color: .nw.popoverShadow, radius: NWDesignMetrics.frameShadowRadius, y: NWDesignMetrics.frameShadowY) }
            .clipShape(shape)
            .nwBorder(Color.nw.lineStrong, radius: NWDesignMetrics.frameRadius)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: NWDesignMetrics.frameRadius + NWDesignMetrics.ringWidth)
                        .inset(by: -NWDesignMetrics.ringWidth)
                        .strokeBorder(Color.nw.running, lineWidth: NWDesignMetrics.ringWidth)
                        .allowsHitTesting(false)
                }
            }
    }
}

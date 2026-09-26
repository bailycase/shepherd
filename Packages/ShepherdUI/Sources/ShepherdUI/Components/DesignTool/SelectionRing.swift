import SwiftUI

/// An element picked inside a board (NWSelectionRing; NWDesignTool, DZTweak), drawn by the canvas
/// over the board from the rect the board reported, at the canvas's zoom. Selected: a 1.5pt
/// `running` ring over a `runningTint` fill, 8pt white handles on its corners, and a `running`
/// tag 4pt above its top-leading corner naming it ("card · Checkout funnel"). Hovered: the ring
/// alone. Selection is running blue, never lantern (pins are lantern).
///
/// Sized to the element; the handles and the tag reach outside it. It takes no events.
public struct NWSelectionRing: View {
    public enum Style: Sendable {
        case selected
        case hover
    }

    let style: Style
    let tag: String?

    public init(_ style: Style = .selected, tag: String? = nil) {
        self.style = style
        self.tag = tag
    }

    public var body: some View {
        Rectangle()
            .fill(style == .selected ? Color.nw.runningTint : .clear)
            .overlay { Rectangle().strokeBorder(Color.nw.running, lineWidth: NWDesignMetrics.elementRingWidth) }
            .overlay { if style == .selected { handles } }
            .overlay(alignment: .topLeading) {
                if style == .selected, let tag {
                    NWSelectionTag(tag).offset(y: -(NWDesignMetrics.tagHeight + NWDesignMetrics.tagGap))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var handles: some View {
        let half = NWDesignMetrics.handleSize / 2
        return ZStack {
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).offset(x: -half, y: -half)
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: half, y: -half)
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).offset(x: -half, y: half)
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).offset(x: half, y: half)
        }
    }

    private var handle: some View {
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.handleRadius)
        return shape.fill(Color.nw.selectionHandle)
            .overlay { shape.strokeBorder(Color.nw.running, lineWidth: NWDesignMetrics.handleLineWidth) }
            .frame(width: NWDesignMetrics.handleSize, height: NWDesignMetrics.handleSize)
    }
}

/// The name over a selected element: 18pt, 6pt padding, radius 4, `running`, white mono 10.5.
public struct NWSelectionTag: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.nwMono(NWDesignMetrics.tagTextSize))
            .foregroundStyle(Color.nw.textOnRunning)
            .lineLimit(1)
            .padding(.horizontal, NWDesignMetrics.tagPadding)
            .frame(height: NWDesignMetrics.tagHeight)
            .background(Color.nw.running, in: RoundedRectangle(cornerRadius: NWDesignMetrics.tagRadius))
            .fixedSize()
    }
}

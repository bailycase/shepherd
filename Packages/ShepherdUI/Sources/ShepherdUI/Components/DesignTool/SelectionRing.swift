import SwiftUI

/// An element picked inside a board (SHSelectionRing; SHDesignTool, DZTweak), drawn by the canvas
/// over the board from the rect the board reported, at the canvas's zoom. Selected: a 1.5pt
/// `running` ring over a `runningTint` fill, 8pt white handles on its corners, and a `running`
/// tag 4pt above its top-leading corner naming it ("card · Checkout funnel"). Hovered: the ring
/// alone. Selection is running blue, never lantern (pins are lantern).
///
/// Sized to the element; the handles and the tag reach outside it. It takes no events.
public struct SHSelectionRing: View {
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
            .fill(style == .selected ? Color.sh.runningTint : .clear)
            .overlay { Rectangle().strokeBorder(Color.sh.running, lineWidth: SHDesignMetrics.elementRingWidth) }
            .overlay { if style == .selected { handles } }
            .overlay(alignment: .topLeading) {
                if style == .selected, let tag {
                    SHSelectionTag(tag).offset(y: -(SHDesignMetrics.tagHeight + SHDesignMetrics.tagGap))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var handles: some View {
        let half = SHDesignMetrics.handleSize / 2
        return ZStack {
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).offset(x: -half, y: -half)
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: half, y: -half)
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).offset(x: -half, y: half)
            handle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).offset(x: half, y: half)
        }
    }

    private var handle: some View {
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.handleRadius)
        return shape.fill(Color.sh.selectionHandle)
            .overlay { shape.strokeBorder(Color.sh.running, lineWidth: SHDesignMetrics.handleLineWidth) }
            .frame(width: SHDesignMetrics.handleSize, height: SHDesignMetrics.handleSize)
    }
}

/// The name over a selected element: 18pt, 6pt padding, radius 4, `running`, white mono 10.5.
public struct SHSelectionTag: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.shMono(SHDesignMetrics.tagTextSize))
            .foregroundStyle(Color.sh.textOnRunning)
            .lineLimit(1)
            .padding(.horizontal, SHDesignMetrics.tagPadding)
            .frame(height: SHDesignMetrics.tagHeight)
            .background(Color.sh.running, in: RoundedRectangle(cornerRadius: SHDesignMetrics.tagRadius))
            .fixedSize()
    }
}

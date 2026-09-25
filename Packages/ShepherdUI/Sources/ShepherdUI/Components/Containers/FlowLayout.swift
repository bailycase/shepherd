import SwiftUI

/// Left-to-right wrapping row (chips): items keep their ideal size and wrap to a new line when
/// the next one would overflow. An item wider than the row is offered the row's width.
public struct NWFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    public init(spacing: CGFloat = NW.Space.m, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = place(in: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = placement.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(placement.sizes[index]))
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], sizes: [CGSize], size: CGSize) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, sizes, CGSize(width: widest, height: subviews.isEmpty ? 0 : y + lineHeight))
    }
}

#Preview("Flow layout") {
    NWPreviewBoth {
        NWFlowLayout {
            ForEach(["shepherd", "This Mac", "claude-opus", "Medium", "a longer value"], id: \.self) { value in
                NWTag(value, mono: true)
            }
        }
        .frame(width: 220, alignment: .leading)
    }
}

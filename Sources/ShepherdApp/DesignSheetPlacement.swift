import SwiftUI

/// Where the design tool's sheets sit over their scrim (`AppLayout.designSheetMiddle`): the middle a third of the way down the
/// window, clear of its top and foot, however tall the sheet is. The sheet gets the room between them to size itself in.
struct DesignSheetPlacement: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let minTop = AppLayout.designSheetMinTop
        let bottom = AppLayout.designSheetBottom
        for subview in subviews {
            let room = ProposedViewSize(width: bounds.width, height: max(0, bounds.height - minTop - bottom))
            let size = subview.sizeThatFits(room)
            let wanted = bounds.height * AppLayout.designSheetMiddle - size.height / 2
            let top = max(minTop, min(wanted, bounds.height - bottom - size.height))
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY + top), anchor: .top, proposal: ProposedViewSize(size))
        }
    }
}

extension View {
    /// The sheet placed by `DesignSheetPlacement`.
    func designSheetPlaced() -> some View { DesignSheetPlacement { self } }
}

import SwiftUI

/// The Project glyph (ProjectLead boards): the supplied `square.stack` icon, drawn as native vector geometry.
///
/// The boards export every icon as a 40-unit contour. This is that contour for the Project mark, point for point
/// (the boards' own `viewBox="0 0 40 40"`, even-odd), not a redrawn approximation. The platform's `square.stack`
/// is the same idea at 0.756 width over height; the supplied contour is 0.801, so the symbol was not used. The
/// geometry is recreated here as a `Shape`: no board code is copied. Draw it through `NWGlyph.project`.
public struct NWProjectGlyph: Shape {
    public init() {}

    /// The contours, in the boards' 40-unit grid: the outer body, its inner opening, and the two caps.
    private static let contours: [[CGFloat]] = [
        [13.75, 16.75, 13.75, 16.25, 14, 16.25, 14.25, 15.75, 14.75, 15.75, 14.75, 15.5, 25.25, 15.5, 25.25, 15.75, 25.75, 15.75, 25.75, 16, 26, 16, 26, 16.5, 26.25, 16.5, 26.25, 17, 26.5, 17, 26.5, 26, 26.25, 26, 26.25, 26.75, 26, 26.75, 25.5, 27.5, 24.25, 27.5, 24.25, 27.75, 15.75, 27.75, 15.75, 27.5, 14.5, 27.5, 14.5, 27.25, 14, 27.25, 14, 26.75, 13.5, 26.5, 13.5, 16.75],
        [15, 18.25, 15, 26, 15.25, 26, 15.25, 26.25, 24.75, 26.25, 24.75, 26, 25, 26, 25, 17.25, 24.75, 17.25, 24.5, 16.75, 15.5, 16.75, 15.5, 17, 15, 17],
        [24.5, 13.75, 24.75, 13.75, 24.75, 14.5, 24.5, 14.5, 24.5, 14.25, 15.25, 14.25, 15.25, 13.75, 15.5, 13.75, 15.5, 13.5, 16, 13.5, 16, 13.25, 23.75, 13.25, 23.75, 13.5, 24.5, 13.5],
        [18.75, 12.25, 16.5, 12.25, 16.5, 12, 16.75, 12, 17, 11.5, 23, 11.5, 23, 11.75, 23.25, 11.75, 23.25, 12.25]
    ]

    /// The boards draw the 40-unit grid at 34.2857pt inside a 14pt slot (0.857pt a unit, centred on the grid's
    /// middle), so the glyph is 11.25 x 14.04pt there. `grid` is that ratio: the grid's size over the slot's.
    static let grid: CGFloat = 40
    static let gridPerSlot: CGFloat = 34.285714 / 14

    public func path(in rect: CGRect) -> Path {
        // The rect is the slot. One unit is `slot * gridPerSlot / grid` points, the grid centred on the slot.
        let unit = min(rect.width, rect.height) * Self.gridPerSlot / Self.grid
        let origin = CGPoint(x: rect.midX - Self.grid * unit / 2, y: rect.midY - Self.grid * unit / 2)
        var path = Path()
        for contour in Self.contours {
            for index in stride(from: 0, to: contour.count - 1, by: 2) {
                let point = CGPoint(x: origin.x + contour[index] * unit, y: origin.y + contour[index + 1] * unit)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        return path
    }
}

/// The Project glyph at the sidebar's size, filled (the contour is the outline's own shape), tinted by the caller.
public struct NWProjectGlyphView: View {
    let tint: Color
    let size: CGFloat

    public init(tint: Color, size: CGFloat = NWSidebarMetrics.projectGlyphBox) {
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        NWProjectGlyph()
            .fill(tint, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

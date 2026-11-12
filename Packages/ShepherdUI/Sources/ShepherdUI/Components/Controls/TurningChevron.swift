import SwiftUI

/// A disclosure chevron: one chevron that turns to point where the disclosure opens, under
/// whatever motion the expansion runs with. Not one image whose symbol name changes with the
/// state: SwiftUI draws a renamed symbol through RenderBox, which loads about 258 MB of
/// accelerated drawing pool for 1.2 to 1.6 s on every animated change (a turning glyph costs
/// about 0.1 MB). The font, color and frame are the caller's. A pair that is up and down turns
/// `chevron.down`; any other turns `chevron.right`, so the closed chevron keeps its drawing and
/// its layout. Under Reduce Motion nothing turns: the two positions cross-fade, as
/// `SHThreadChevron` does.
public struct SHTurningChevron: View {
    /// Where the chevron points.
    public enum Direction: Sendable {
        case up, right, down

        /// The turn from `chevron.right`, clockwise.
        fileprivate var degrees: Double {
            switch self {
            case .up: -90
            case .right: 0
            case .down: 90
            }
        }
    }

    let isOpen: Bool
    let closed: Direction
    let open: Direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `closed` and `open` are the directions it points in each state: right and down for a row
    /// that opens below it.
    public init(isOpen: Bool, closed: Direction = .right, open: Direction = .down) {
        self.isOpen = isOpen
        self.closed = closed
        self.open = open
    }

    public var body: some View {
        if reduceMotion {
            ZStack {
                glyph(closed).opacity(isOpen ? 0 : 1)
                glyph(open).opacity(isOpen ? 1 : 0)
            }
        } else {
            glyph(isOpen ? open : closed)
        }
    }

    private var base: Direction { closed == .right || open == .right ? .right : .down }

    @ViewBuilder private func glyph(_ direction: Direction) -> some View {
        let turn = Angle.degrees(direction.degrees - base.degrees)
        if base == .right {
            Image(systemName: "chevron.right").rotationEffect(turn)
        } else {
            Image(systemName: "chevron.down").rotationEffect(turn)
        }
    }
}

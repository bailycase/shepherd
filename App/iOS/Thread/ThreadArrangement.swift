import SwiftUI
import ShepherdUI

/// The thread in iPhone Duo's laptop pose (DuoLaptop, DuoLaptopOpen): an overlay `ArrangementView` with the composer primary and the
/// transcript (or the terminal) secondary. Half open, the system puts the transcript above the fold and the composer below it; flat or
/// closed, the composer floats over the transcript's foot as a card. The pose is Apple's to lay out: this only says which view is which.
/// It needs the iOS 27.1 SDK and system; elsewhere it is today's thread, the composer under the transcript. Never inside a split view,
/// list or scroll view (HIG): `PadShell` gives the arranged thread the window.
struct ThreadArrangement<Secondary: View, Composer: View>: View {
    @ViewBuilder let secondary: Secondary
    @ViewBuilder let composer: Composer
    /// The floating card's height, kept clear at the transcript's foot.
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let folded = proxy.horizontalFold != nil
                ArrangementView {
                    composer
                        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: MobileLayout.cardRadius))
                        .shBorder(Color.sh.lineSubtle, radius: MobileLayout.cardRadius)
                        .frame(maxWidth: MobileLayout.threadMaxWidth)
                        .padding(MobileLayout.gutter)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                        .overlayArrangementEdge(VerticalEdge.bottom)
                } secondary: {
                    secondary.safeAreaPadding(.bottom, folded ? 0 : cardHeight)
                }
                .arrangementViewStyle(.overlay)
            }
        } else {
            stacked
        }
        #else
        stacked
        #endif
    }

    private var stacked: some View {
        secondary.safeAreaInset(edge: .bottom, spacing: 0) { composer.background(Color.sh.bgWindow) }
    }
}

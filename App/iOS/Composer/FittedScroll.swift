import SwiftUI

extension EnvironmentValues {
    /// The most height the composer may take (a share of the thread's), so a long question or
    /// a tall queue at a large text size scrolls inside it instead of pushing the thread off.
    @Entry var composerMaxHeight: CGFloat = .infinity
}

extension View {
    /// Its content at its own height up to `maxHeight`, scrolling past it. `swipeActions` on
    /// the rows work, since the scroll view is their container.
    func fittedScroll(maxHeight: CGFloat) -> some View {
        modifier(FittedScroll(maxHeight: maxHeight))
    }
}

private struct FittedScroll: ViewModifier {
    let maxHeight: CGFloat
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .swipeActionsContainer()
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, maxHeight))
    }
}

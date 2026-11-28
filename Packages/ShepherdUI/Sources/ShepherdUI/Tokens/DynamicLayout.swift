import SwiftUI

extension DynamicTypeSize {
    /// A row's layout: its parts side by side, and from the accessibility sizes one under another, so a title never gives its room to the
    /// words beside it (the boards at the default size are unchanged). Stacked parts lead; side by side they center.
    public func shAdaptiveLayout(spacing: CGFloat, stackedSpacing: CGFloat = SH.Space.xs) -> AnyLayout {
        isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: stackedSpacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
    }

    /// The largest size a bar's own title scales to: the system's bars stop growing here, and the glass buttons beside the title never grow.
    public static let shBarTitleLimit: DynamicTypeSize = .xxxLarge
}

extension View {
    /// A navigation bar's title and subtitle, capped at `DynamicTypeSize.shBarTitleLimit` for text SwiftUI scales (system fonts); the
    /// Shepherd fonts are capped where they are built: `Font.shBar`, `shBarSans`, `shBarMono`.
    public func shBarTitleType() -> some View { dynamicTypeSize(...DynamicTypeSize.shBarTitleLimit) }
}

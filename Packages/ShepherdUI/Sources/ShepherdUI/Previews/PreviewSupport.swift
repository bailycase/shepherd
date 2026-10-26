import SwiftUI

/// Renders `content` twice, dark then light, each on `bgWindow`: every component preview shows
/// both appearances at once.
struct SHPreviewBoth<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            ForEach([ColorScheme.dark, .light], id: \.self) { scheme in
                content()
                    .padding(SH.Space.xxl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.sh.bgWindow)
                    .environment(\.colorScheme, scheme)
            }
        }
    }
}

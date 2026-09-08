import SwiftUI

struct PiOutdatedOverlay: View {
    var body: some View {
        Text("pi outdated")
            .font(Fonts.mono(10, .semibold))
            .foregroundStyle(Tokens.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Tokens.destructive.opacity(0.62))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(6)
    }
}

#if os(macOS)
import SwiftUI

/// "on mini ⌄" after a thread's title and space (GXRemote): where a thread that runs on another Mac runs, in `textTertiary`
/// with a chevron; pressing it opens the menu about that Mac.
public struct SHHostChip: View {
    let host: String
    let action: () -> Void
    @State private var hovering = false

    public init(host: String, action: @escaping () -> Void) {
        self.host = host
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.xs) {
                Text("on \(host)").lineLimit(1)
                SHChipChevron()
            }
            .foregroundStyle(hovering ? Color.sh.textSecondary : Color.sh.textTertiary)
            .padding(.leading, SH.Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shHelp("Running on \(host)")
        .accessibilityLabel("Running on \(host)")
        .accessibilityHint("Opens a menu")
    }
}
#endif

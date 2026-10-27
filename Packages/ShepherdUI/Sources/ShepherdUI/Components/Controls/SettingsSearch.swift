import SwiftUI

/// The native search fields drawn by the Settings boards: 34pt navigation and 32pt filters.
public struct SHSettingsSearchField: View {
    public enum Placement { case navigation, sites, subagents }
    let placeholder: String
    @Binding var text: String
    let placement: Placement
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    public init(_ placeholder: String, text: Binding<String>, placement: Placement) {
        self.placeholder = placeholder
        _text = text
        self.placement = placement
    }

    public var body: some View {
        let glyph: SHGlyph.Settings = placement == .sites ? .browserSearch : .search
        HStack(spacing: SH.Space.m) {
            glyph.image.foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(placement == .navigation ? Color.sh.textTertiary : Color.sh.textSecondary))
                .textFieldStyle(.plain).font(.shSans(SHSettingsNavMetrics.textSize))
                .foregroundStyle(Color.sh.textPrimary).tint(Color.sh.lantern)
                .focused($focused).accessibilityLabel(placeholder)
            if text.isEmpty, placement == .navigation {
                Text("⌘F").font(.shMono(SHTextStyle.micro.size)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            } else if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.shSans(SHTextStyle.micro.size))
                        .foregroundStyle(Color.sh.textTertiary)
                        .frame(width: SH.Height.controlS, height: SH.Height.controlS).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, SHSettingsControlMetrics.fieldPadding + SHSettingsNavMetrics.borderWidth)
            .frame(height: placement == .navigation ? SHSettingsNavMetrics.searchHeight : SH.Height.controlL)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SHSettingsControlMetrics.radius))
            .shBorder(Color.sh.lineStrong, radius: SHSettingsControlMetrics.radius, width: SHSettingsNavMetrics.borderWidth)
            .shFocusRing(focused, radius: SHSettingsControlMetrics.radius, color: Color.sh.running)
            .shEnabledOpacity(enabled)
    }
}

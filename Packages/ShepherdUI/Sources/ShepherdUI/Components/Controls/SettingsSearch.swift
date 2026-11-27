import SwiftUI

/// The native search fields drawn by the Settings boards: the 28pt sunken navigation field (no border) and 32pt filters.
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
        let navigation = placement == .navigation
        let radius = SHSettingsControlMetrics.searchRadius
        HStack(spacing: SH.Space.m) {
            glyph.image.foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.sh.textTertiary))
                .textFieldStyle(.plain).font(.shSans(SHSettingsControlMetrics.textSize))
                .foregroundStyle(Color.sh.textPrimary).tint(Color.sh.lantern)
                .focused($focused).accessibilityLabel(placeholder)
            if text.isEmpty, placement == .navigation {
                Text("⌘F").font(.shSans(SHTextStyle.caption.size)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            } else if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.shSans(SHTextStyle.micro.size))
                        .foregroundStyle(Color.sh.textTertiary)
                        .frame(width: SH.Height.controlS, height: SH.Height.controlS).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, SHSettingsControlMetrics.fieldPadding + SHSettingsNavMetrics.borderWidth)
            .frame(height: placement == .navigation ? SHSettingsNavMetrics.searchHeight : SHSettingsControlMetrics.fieldHeight)
            .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: radius))
            .shFocusRing(focused, radius: radius, color: Color.sh.running)
            .shEnabledOpacity(enabled)
    }
}

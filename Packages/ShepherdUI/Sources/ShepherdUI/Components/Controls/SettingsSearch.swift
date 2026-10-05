import SwiftUI

/// The native search fields drawn by the Settings boards: 34pt navigation and 32pt filters.
public struct NWSettingsSearchField: View {
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
        let glyph: NWGlyph.Settings = placement == .sites ? .browserSearch : .search
        HStack(spacing: NW.Space.m) {
            glyph.image.foregroundStyle(Color.nw.textTertiary).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(placement == .navigation ? Color.nw.textTertiary : Color.nw.textSecondary))
                .textFieldStyle(.plain).font(.nwSans(NWSettingsNavMetrics.textSize))
                .foregroundStyle(Color.nw.textPrimary).tint(Color.nw.lantern)
                .focused($focused).accessibilityLabel(placeholder)
            if text.isEmpty, placement == .navigation {
                Text("⌘F").font(.nwMono(NWTextStyle.micro.size)).foregroundStyle(Color.nw.textTertiary).accessibilityHidden(true)
            } else if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.nwSans(NWTextStyle.micro.size))
                        .foregroundStyle(Color.nw.textTertiary)
                        .frame(width: NW.Height.controlS, height: NW.Height.controlS).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, NWSettingsControlMetrics.fieldPadding + NWSettingsNavMetrics.borderWidth)
            .frame(height: placement == .navigation ? NWSettingsNavMetrics.searchHeight : NW.Height.controlL)
            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NWSettingsControlMetrics.radius))
            .nwBorder(Color.nw.lineStrong, radius: NWSettingsControlMetrics.radius, width: NWSettingsNavMetrics.borderWidth)
            .nwFocusRing(focused, radius: NWSettingsControlMetrics.radius, color: Color.nw.running)
            .nwEnabledOpacity(enabled)
    }
}

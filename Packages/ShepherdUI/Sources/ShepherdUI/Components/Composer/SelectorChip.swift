import SwiftUI

/// The selector chip's measures (the phone and iPad New thread boards): 32pt capsules with a
/// 13pt icon and label, 8pt apart.
public enum NWSelectorChipMetrics {
    public static let height: CGFloat = NW.Height.controlL
    public static let iconSize: CGFloat = 13
    public static let labelSize: CGFloat = 13
    public static let spacing: CGFloat = NW.Space.m
}

/// A chip that shows a choice and opens its picker (New thread's repo, host, model and
/// thinking): an outlined capsule with an icon, the value and a chevron. `active` wears the
/// lantern line while its picker is open.
public struct NWSelectorChip: View {
    let label: String
    let systemImage: String
    let mono: Bool
    let active: Bool
    let accessibilityName: String

    /// `accessibilityName` says what the chip chooses ("Repo"); VoiceOver reads it with the value.
    public init(_ label: String, systemImage: String, mono: Bool = true, active: Bool = false, accessibilityName: String) {
        self.label = label
        self.systemImage = systemImage
        self.mono = mono
        self.active = active
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            Image(systemName: systemImage)
                .font(.nwSans(NWSelectorChipMetrics.iconSize, .medium))
                .foregroundStyle(nw.textSecondary)
                .accessibilityHidden(true)
            Text(label)
                .font(mono ? .nwMono(NWSelectorChipMetrics.labelSize) : .nwSans(NWSelectorChipMetrics.labelSize))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
            NWChipChevron()
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: NWSelectorChipMetrics.height)
        .background(nw.bgRaised, in: Capsule())
        .nwBorder(active ? nw.lantern : nw.lineStrong, in: Capsule())
        .contentShape(Capsule())
        .nwComponentAnimation(.hover, value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityName): \(label)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A button style for a label that draws its own chrome (a chip, a row): it dims while pressed
/// and grows its hit area to the touch minimum without changing its layout.
public struct NWPressableStyle: ButtonStyle {
    let height: CGFloat

    public init(height: CGFloat = NW.Height.controlL) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        NWPressable(configuration: configuration, height: height)
    }
}

private struct NWPressable: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let outset = max(0, (NW.Height.touch - height) / 2)
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .nwEnabledOpacity(enabled)
            .contentShape(.interaction, Rectangle().inset(by: -outset))
            .nwAnimation(.hover, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == NWPressableStyle {
    public static func nwPressable(height: CGFloat = NW.Height.controlL) -> NWPressableStyle { NWPressableStyle(height: height) }
}

#Preview("Selector chips") {
    NWPreviewBoth {
        NWFlowLayout(spacing: NWSelectorChipMetrics.spacing) {
            Button {} label: { NWSelectorChip("shepherd", systemImage: "book.closed", active: true, accessibilityName: "Repo") }
            Button {} label: { NWSelectorChip("This Mac", systemImage: "desktopcomputer", accessibilityName: "Host") }
            Button {} label: { NWSelectorChip("claude-opus", systemImage: "sparkle", accessibilityName: "Model") }
            Button {} label: { NWSelectorChip("Medium", systemImage: "lightbulb", mono: false, accessibilityName: "Thinking") }
        }
        .buttonStyle(.nwPressable())
        .frame(width: 360, alignment: .leading)
    }
}

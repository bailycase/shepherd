import SwiftUI

/// The selector chip's measures (the phone and iPad New thread boards): 32pt capsules with a
/// 13pt icon and label, 8pt apart.
public enum SHSelectorChipMetrics {
    public static let height: CGFloat = SH.Height.controlL
    public static let iconSize: CGFloat = 13
    public static let labelSize: CGFloat = 13
    public static let spacing: CGFloat = SH.Space.m
}

/// A chip that shows a choice and opens its picker (New thread's repo, host, model and
/// thinking): an outlined capsule with an icon, the value and a chevron. `active` wears the
/// lantern line while its picker is open.
public struct SHSelectorChip: View {
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
        let sh = Color.sh
        HStack(spacing: SH.Space.s) {
            Image(systemName: systemImage)
                .font(.shSans(SHSelectorChipMetrics.iconSize, .medium))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            Text(label)
                .font(mono ? .shMono(SHSelectorChipMetrics.labelSize) : .shSans(SHSelectorChipMetrics.labelSize))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
            SHChipChevron()
        }
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: SHSelectorChipMetrics.height)
        .background(sh.bgRaised, in: Capsule())
        .shBorder(active ? sh.lantern : sh.lineStrong, in: Capsule())
        .contentShape(Capsule())
        .shComponentAnimation(.hover, value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityName): \(label)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A button style for a label that draws its own chrome (a chip, a row): it dims while pressed
/// and grows its hit area to the touch minimum without changing its layout.
public struct SHPressableStyle: ButtonStyle {
    let height: CGFloat

    public init(height: CGFloat = SH.Height.controlL) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        SHPressable(configuration: configuration, height: height)
    }
}

private struct SHPressable: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let outset = max(0, (SH.Height.touch - height) / 2)
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .shEnabledOpacity(enabled)
            .contentShape(.interaction, Rectangle().inset(by: -outset))
            .shAnimation(.hover, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SHPressableStyle {
    public static func shPressable(height: CGFloat = SH.Height.controlL) -> SHPressableStyle { SHPressableStyle(height: height) }
}

#Preview("Selector chips") {
    SHPreviewBoth {
        SHFlowLayout(spacing: SHSelectorChipMetrics.spacing) {
            Button {} label: { SHSelectorChip("shepherd", systemImage: "book.closed", active: true, accessibilityName: "Repo") }
            Button {} label: { SHSelectorChip("This Mac", systemImage: "desktopcomputer", accessibilityName: "Host") }
            Button {} label: { SHSelectorChip("claude-opus", systemImage: "sparkle", accessibilityName: "Model") }
            Button {} label: { SHSelectorChip("Medium", systemImage: "lightbulb", mono: false, accessibilityName: "Thinking") }
        }
        .buttonStyle(.shPressable())
        .frame(width: 360, alignment: .leading)
    }
}

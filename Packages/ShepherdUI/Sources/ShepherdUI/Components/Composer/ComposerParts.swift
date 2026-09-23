import SwiftUI

/// The composer's dimensions (NWComposer board).
public enum NWComposerMetrics {
    /// Chips and the attach button under the field.
    public static let chipHeight: CGFloat = 26
    /// Send and Stop.
    public static let actionSize: CGFloat = 28
    public static let fieldMinHeight: CGFloat = 40
    public static let fieldMaxLines = 8
    /// Menus: 28pt rows under a 24pt section header, in a 6pt-padded popover.
    public static let menuRowHeight: CGFloat = 28
    public static let menuHeaderHeight: CGFloat = 24
    public static let menuMaxRows = 8
    public static let slashMenuWidth: CGFloat = 448
    public static let slashNameWidth: CGFloat = 150
    public static let modelPickerWidth: CGFloat = 260
    public static let modelSearchHeight: CGFloat = 30
    public static let modelPickerMaxHeight: CGFloat = 360
    public static let thinkingMenuWidth: CGFloat = 220
    /// The `bgSelected` ring around a focused composer card (the thread's and the Steer card).
    public static let focusRing: CGFloat = 3
}

/// The composer card (NWComposer board): `bgRaised`, a 1px strong line, radius 8. While the
/// field has focus (or a menu is open, or a drop hovers) the line turns `textTertiary` with a
/// 3pt `bgSelected` ring. Top: attachments; then the field (it grows to 8 lines); then one row
/// of controls. Nothing else lives under the field.
public struct NWComposer<Top: View, Field: View, Controls: View>: View {
    let isFocused: Bool
    let top: Top
    let field: Field
    let controls: Controls

    public init(isFocused: Bool, @ViewBuilder top: () -> Top, @ViewBuilder field: () -> Field,
                @ViewBuilder controls: () -> Controls) {
        self.isFocused = isFocused
        self.top = top()
        self.field = field()
        self.controls = controls()
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: top) { subviews in
                if !subviews.isEmpty {
                    HStack(spacing: NW.Space.s) { subviews }
                        .padding(.top, 10)
                        .padding(.horizontal, NW.Space.l)
                }
            }
            field
                .padding(EdgeInsets(top: NW.Space.l, leading: 14, bottom: NW.Space.xs, trailing: 14))
                .frame(minHeight: NWComposerMetrics.fieldMinHeight, alignment: .topLeading)
            HStack(spacing: NW.Space.xxs) { controls }
                .padding(EdgeInsets(top: NW.Space.xs, leading: NW.Space.s, bottom: NW.Space.s, trailing: NW.Space.s))
        }
        .background(nw.bgRaised, in: shape)
        .nwBorder(isFocused ? nw.textTertiary : nw.lineStrong, radius: NW.Radius.m)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: NW.Radius.m + NWComposerMetrics.focusRing)
                    .inset(by: -NWComposerMetrics.focusRing).fill(nw.bgSelected)
            }
        }
    }
}

extension NWComposer where Top == EmptyView {
    public init(isFocused: Bool, @ViewBuilder field: () -> Field, @ViewBuilder controls: () -> Controls) {
        self.init(isFocused: isFocused, top: { EmptyView() }, field: field, controls: controls)
    }
}

/// A ghost chip in the composer's action row (commands, model, thinking): 26pt, 12pt
/// `textSecondary`, radius 6; hover and active fill `bgHover`.
public struct NWComposerChipStyle: ButtonStyle {
    let active: Bool

    public init(active: Bool = false) { self.active = active }

    public func makeBody(configuration: Configuration) -> some View {
        NWComposerChip(configuration: configuration, active: active)
    }
}

extension ButtonStyle where Self == NWComposerChipStyle {
    public static func nwComposerChip(active: Bool = false) -> NWComposerChipStyle { NWComposerChipStyle(active: active) }
}

private struct NWComposerChip: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.nwSans(12))
            .foregroundStyle(.nw.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, NW.Space.m)
            .frame(height: NWComposerMetrics.chipHeight)
            .background(enabled && (active || hovering || configuration.isPressed) ? Color.nw.bgHover : .clear,
                        in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
            .onHover { hovering = $0 }
            .nwFocusRing(radius: NW.Radius.s)
    }
}

/// The down chevron chips and popups use (10pt, `textTertiary`).
public struct NWChipChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.nw.textTertiary)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

/// The composer's single action, a 28pt circle: Send (an arrow on the lantern fill, 35% until
/// there is something to send) or Stop (a square on `failed`) while a turn runs.
public struct NWComposerActionButton: View {
    public enum Mode: Sendable { case send, stop }

    let mode: Mode
    let enabled: Bool
    let action: () -> Void

    public init(_ mode: Mode, enabled: Bool = true, action: @escaping () -> Void) {
        self.mode = mode
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        Button(action: action) {
            switch mode {
            case .send:
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(nw.textOnLantern)
            case .stop:
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(nw.textOnFailed)
            }
        }
        .buttonStyle(NWComposerActionStyle(fill: mode == .send ? nw.lantern : nw.failed))
        .disabled(!enabled)
        .accessibilityLabel(mode == .send ? "Send" : "Stop")
    }
}

/// The action's circle. Its own style, because the plain style dims a disabled label again on
/// top of the board's 35%.
private struct NWComposerActionStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        NWComposerActionCircle(configuration: configuration, fill: fill)
    }
}

private struct NWComposerActionCircle: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
            .background(fill.mix(with: .black, by: enabled && configuration.isPressed ? 0.1 : 0), in: Circle())
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Circle())
            .nwFocusRingCircle()
    }
}

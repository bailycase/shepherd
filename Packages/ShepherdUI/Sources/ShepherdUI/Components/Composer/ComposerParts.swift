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
    /// The slash menu (SlashMenu board) spans the composer card: 36pt rows with 12pt sides, the
    /// command in a column at least 150pt wide.
    public static let slashRowHeight: CGFloat = 36
    public static let slashNameWidth: CGFloat = 150
    /// The model picker (ModelPicker board): 380pt, two-line 40pt rows, sections 4pt apart.
    public static let modelPickerWidth: CGFloat = 380
    public static let modelRowHeight: CGFloat = 40
    public static let modelSectionGap: CGFloat = 4
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
        // As the card eases to a new height (a question taking the field's place, attachments
        // arriving), what it holds is revealed by its edge rather than drawn outside it.
        .clipShape(shape)
        // The line and the ring fade with focus; keyed on focus alone, so they never lag the
        // card as it grows.
        .overlay {
            Color.clear
                .nwBorder(isFocused ? nw.textTertiary : nw.lineStrong, radius: NW.Radius.m)
                .nwAnimation(.hover, value: isFocused)
                .allowsHitTesting(false)
        }
        .background {
            RoundedRectangle(cornerRadius: NW.Radius.m + NWComposerMetrics.focusRing)
                .inset(by: -NWComposerMetrics.focusRing).fill(nw.bgSelected)
                .opacity(isFocused ? 1 : 0)
                .nwAnimation(.hover, value: isFocused)
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
        let filled = enabled && (active || hovering || configuration.isPressed)
        configuration.label
            .font(.nwSans(12))
            .foregroundStyle(.nw.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, NW.Space.m)
            .frame(height: NWComposerMetrics.chipHeight)
            .background {
                RoundedRectangle(cornerRadius: NW.Radius.s).fill(filled ? Color.nw.bgHover : .clear)
                    .nwAnimation(.hover, value: filled)
            }
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
            .onHover { hovering = $0 }
            .nwFocusRing(radius: NW.Radius.s)
            .nwTouchTarget(height: NWComposerMetrics.chipHeight)
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

/// The composer's action, a 28pt circle: Send (an arrow on the lantern fill, 35% until there is
/// something to send) or Stop (a square on `failed`) while a turn runs. With a draft while a turn
/// runs, Stop steps aside outlined (a hairline, a `failed` square, no fill) and Send takes the
/// corner.
public struct NWComposerActionButton: View {
    public enum Mode: Sendable { case send, stop }

    let mode: Mode
    let outlined: Bool
    let ringed: Bool
    let enabled: Bool
    let action: () -> Void

    /// `outlined` draws Stop beside Send; `ringed` wears Send's 3pt `lanternTint` ring while its
    /// Send menu is open.
    public init(_ mode: Mode, outlined: Bool = false, ringed: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.mode = mode
        self.outlined = outlined && mode == .stop
        self.ringed = ringed && mode == .send
        self.enabled = enabled
        self.action = action
    }

    /// Send and Stop are one glyph, so a turn starting or ending blends the fill and the glyph
    /// in place, together. (A symbol replace runs on SF Symbols' own, slower clock: it left an
    /// arrow on the red Stop fill for a moment.)
    public var body: some View {
        let nw = Color.nw
        let send = mode == .send
        Button(action: action) {
            Image(systemName: send ? "arrow.up" : "stop.fill")
                .font(.system(size: send ? 13 : 10, weight: .semibold))
                .foregroundStyle(send ? nw.textOnLantern : outlined ? nw.failed : nw.textOnFailed)
                .nwContentTransition(.crossFade)
        }
        .buttonStyle(NWComposerActionStyle(fill: send ? nw.lantern : outlined ? nil : nw.failed))
        .disabled(!enabled)
        .background {
            Circle().inset(by: -NWComposerMetrics.focusRing).fill(nw.lanternTint)
                .opacity(ringed ? 1 : 0)
                .nwAnimation(.hover, value: ringed)
        }
        .nwAnimation(.content, value: send)
        .nwAnimation(.content, value: outlined)
        .accessibilityLabel(send ? "Send" : "Stop")
    }
}

/// The action's circle. Its own style, because the plain style dims a disabled label again on
/// top of the board's 35%. No fill: the outlined Stop, `bgHover` under the pointer.
private struct NWComposerActionStyle: ButtonStyle {
    let fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        NWComposerActionCircle(configuration: configuration, fill: fill)
    }
}

private struct NWComposerActionCircle: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color?
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let nw = Color.nw
        let pressed = enabled && configuration.isPressed
        let background = fill.map { $0.mix(with: .black, by: pressed ? 0.1 : 0) }
            ?? (pressed ? nw.bgSelected : enabled && hovering ? nw.bgHover : .clear)
        configuration.label
            .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
            .background(background, in: Circle())
            .nwBorder(fill == nil ? nw.lineStrong : .clear, in: Circle())
            // Send brightens as soon as there is something to send.
            .opacity(enabled ? 1 : 0.35)
            .nwAnimation(.hover, value: enabled)
            .nwAnimation(.hover, value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .nwFocusRingCircle()
            .nwTouchTarget(height: NWComposerMetrics.actionSize, width: NWComposerMetrics.actionSize)
    }
}

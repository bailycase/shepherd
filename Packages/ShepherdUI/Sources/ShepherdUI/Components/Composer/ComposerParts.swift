import SwiftUI

/// The composer's dimensions (SHComposer board).
public enum SHComposerMetrics {
    /// Chips and the attach button under the field.
    public static let chipHeight: CGFloat = 26
    /// Send and Stop.
    public static let actionSize: CGFloat = 28
    public static let fieldMinHeight: CGFloat = 56
    public static let modelSettingsWidth: CGFloat = 328
    public static let branchSymbol: CGFloat = 13
    public static let branchText: CGFloat = 11.5
    public static let branchCount: CGFloat = 10.5
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
    /// The `bgSelected` ring around a focused composer card (the thread's and the Steer card).
    public static let focusRing: CGFloat = 3
    /// A chip's glyph (the Fast bolt, `SHFastBolt`).
    public static let chipSymbol: CGFloat = 11
}

/// The composer's size (SHDesignTool › Chat composer). `.regular` is the thread's and New
/// design's; `.compact` is for a pane under 520pt (a design's 420pt chat), where the
/// model-settings button drops the thinking level and keeps the Fast bolt. The controls, the
/// ring and Send are the same at both sizes.
public enum SHComposerSize: Sendable, Hashable {
    case regular
    case compact

    /// The chips' words ("commands", "Thinking") show: at the regular size, unless the row has
    /// no room for them (`short`).
    public func showsChipWords(short: Bool = false) -> Bool {
        self == .regular && !short
    }
}

extension EnvironmentValues {
    @Entry public var shComposerSize: SHComposerSize = .regular
}

extension View {
    /// Draws the composers inside at `size` (`SHComposerSize`).
    public func shComposerSize(_ size: SHComposerSize) -> some View {
        environment(\.shComposerSize, size)
    }
}

/// The commands chip's label: "/ commands", or "/" alone at the compact size or when the row
/// is short of room.
public struct SHComposerCommandsLabel: View {
    let short: Bool
    @Environment(\.shComposerSize) private var size

    public init(short: Bool = false) { self.short = short }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Text("/").font(.sh(.code))
            if size.showsChipWords(short: short) { Text("commands") }
        }
    }
}

/// The composer card (SHComposer board): `bgRaised`, a 1px strong line, radius 8. While the
/// field has focus (or a menu is open, or a drop hovers) the line turns `textTertiary` with a
/// 3pt `bgSelected` ring. Top: attachments; then the field (it grows to 8 lines); then one row
/// of controls. Nothing else lives under the field.
public struct SHComposer<Top: View, Field: View, Controls: View>: View {
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
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: top) { subviews in
                if !subviews.isEmpty {
                    // Chips wrap to more rows (design references are wide).
                    SHFlowLayout(spacing: SH.Space.s, lineSpacing: SH.Space.s) { subviews }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .padding(.horizontal, SH.Space.l)
                }
            }
            field
                .padding(EdgeInsets(top: SH.Space.l, leading: 14, bottom: SH.Space.xs, trailing: 14))
                .frame(minHeight: SHComposerMetrics.fieldMinHeight, alignment: .topLeading)
            HStack(spacing: SH.Space.xxs) { controls }
                .padding(EdgeInsets(top: SH.Space.xs, leading: SH.Space.s, bottom: SH.Space.s, trailing: SH.Space.s))
        }
        .background(sh.bgRaised, in: shape)
        // As the card eases to a new height (a question taking the field's place, attachments
        // arriving), what it holds is revealed by its edge rather than drawn outside it.
        .clipShape(shape)
        // The line and the ring fade with focus; keyed on focus alone, so they never lag the
        // card as it grows.
        .overlay {
            Color.clear
                .shBorder(isFocused ? sh.textTertiary : sh.lineStrong, radius: SH.Radius.m)
                .shAnimation(.hover, value: isFocused)
                .allowsHitTesting(false)
        }
        .background {
            RoundedRectangle(cornerRadius: SH.Radius.m + SHComposerMetrics.focusRing)
                .inset(by: -SHComposerMetrics.focusRing).fill(sh.bgSelected)
                .opacity(isFocused ? 1 : 0)
                .shAnimation(.hover, value: isFocused)
        }
    }
}

extension SHComposer where Top == EmptyView {
    public init(isFocused: Bool, @ViewBuilder field: () -> Field, @ViewBuilder controls: () -> Controls) {
        self.init(isFocused: isFocused, top: { EmptyView() }, field: field, controls: controls)
    }
}

/// A ghost chip in the composer's action row (commands, model, thinking): 26pt, 12pt
/// `textSecondary`, radius 6; hover and active fill `bgHover`.
public struct SHComposerChipStyle: ButtonStyle {
    let active: Bool

    public init(active: Bool = false) { self.active = active }

    public func makeBody(configuration: Configuration) -> some View {
        SHComposerChip(configuration: configuration, active: active)
    }
}

extension ButtonStyle where Self == SHComposerChipStyle {
    public static func shComposerChip(active: Bool = false) -> SHComposerChipStyle { SHComposerChipStyle(active: active) }
}

private struct SHComposerChip: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let filled = enabled && (active || hovering || configuration.isPressed)
        configuration.label
            .font(.shSans(12))
            .foregroundStyle(.sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.m)
            .frame(height: SHComposerMetrics.chipHeight)
            .background {
                RoundedRectangle(cornerRadius: SH.Radius.s).fill(filled ? Color.sh.bgHover : .clear)
                    .shAnimation(.hover, value: filled)
            }
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
            .onHover { hovering = $0 }
            .shFocusRing(radius: SH.Radius.s)
            .shTouchTarget(height: SHComposerMetrics.chipHeight)
    }
}

/// The down chevron chips and popups use (10pt, `textTertiary`).
public struct SHChipChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.sh.textTertiary)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

/// The composer's action, a 28pt circle: Send (an arrow on the lantern fill, 35% until there is
/// something to send) or Stop (a square on `failed`) while a turn runs and there is nothing to
/// send. It is the composer's only action: with input while a turn runs it is Send again.
public struct SHComposerActionButton: View {
    public enum Mode: Sendable { case send, stop }

    let mode: Mode
    let ringed: Bool
    let enabled: Bool
    let action: () -> Void

    /// `ringed` wears Send's 3pt `lanternTint` ring while its Send menu is open.
    public init(_ mode: Mode, ringed: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.mode = mode
        self.ringed = ringed && mode == .send
        self.enabled = enabled
        self.action = action
    }

    /// Send and Stop are one glyph, so a turn starting or ending blends the fill and the glyph
    /// in place, together. (A symbol replace runs on SF Symbols' own, slower clock: it left an
    /// arrow on the red Stop fill for a moment.)
    public var body: some View {
        let sh = Color.sh
        let send = mode == .send
        Button(action: action) {
            Image(systemName: send ? "arrow.up" : "stop.fill")
                .font(.system(size: send ? 13 : 10, weight: .semibold))
                .foregroundStyle(send ? sh.textOnLantern : sh.textOnFailed)
                .shContentTransition(.crossFade)
        }
        .buttonStyle(SHComposerActionStyle(fill: send ? sh.lantern : sh.failed))
        .disabled(!enabled)
        .background {
            Circle().inset(by: -SHComposerMetrics.focusRing).fill(sh.lanternTint)
                .opacity(ringed ? 1 : 0)
                .shAnimation(.hover, value: ringed)
        }
        .shAnimation(.content, value: send)
        .accessibilityLabel(send ? "Send" : "Stop")
    }
}

/// The action's circle. Its own style, because the plain style dims a disabled label again on
/// top of the board's 35%.
private struct SHComposerActionStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        SHComposerActionCircle(configuration: configuration, fill: fill)
    }
}

private struct SHComposerActionCircle: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let pressed = enabled && configuration.isPressed
        configuration.label
            .frame(width: SHComposerMetrics.actionSize, height: SHComposerMetrics.actionSize)
            .background(fill.mix(with: .black, by: pressed ? 0.1 : 0), in: Circle())
            // Send brightens as soon as there is something to send.
            .opacity(enabled ? 1 : 0.35)
            .shAnimation(.hover, value: enabled)
            .shAnimation(.hover, value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .shFocusRingCircle()
            .shTouchTarget(height: SHComposerMetrics.actionSize, width: SHComposerMetrics.actionSize)
    }
}

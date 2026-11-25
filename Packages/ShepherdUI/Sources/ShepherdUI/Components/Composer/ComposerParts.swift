import SwiftUI

/// The composer's dimensions (SHComposer board).
public enum SHComposerMetrics {
    /// Chips and the attach button under the field.
    public static let chipHeight: CGFloat = 26
    /// Send and Stop (the boards' 30pt `.send`), and the Mac's attach plus.
    #if os(macOS)
    public static let actionSize: CGFloat = 30
    #else
    public static let actionSize: CGFloat = 28
    #endif
    /// The card's corner: the boards' 14 on the Mac.
    #if os(macOS)
    public static let radius: CGFloat = SH.Radius.xl
    #else
    public static let radius: CGFloat = SH.Radius.m
    #endif
    /// The Mac's one-line card (the boards' `.line`): 48pt, padded 8 at its sides, its parts 10pt apart.
    public static let lineHeight: CGFloat = 48
    public static let linePadding: CGFloat = 8
    public static let lineGap: CGFloat = 10
    /// New thread's card puts the words over the line, padded 16 above and at the sides, at least 64pt tall.
    public static let stackedFieldPadding: CGFloat = 16
    public static let stackedFieldMinHeight: CGFloat = 64
    /// Send's arrow and Stop's square.
    public static let sendGlyph: CGFloat = 13
    public static let stopGlyph: CGFloat = 10
    public static let fieldMinHeight: CGFloat = 56
    public static let modelSettingsWidth: CGFloat = 328
    public static let branchSymbol: CGFloat = 13
    public static let branchText: CGFloat = 11.5
    public static let branchCount: CGFloat = 10.5
    public static let fieldMaxLines = 8
    /// Menus: 28pt rows under a 24pt section header, in a 6pt-padded popover.
    #if os(macOS)
    /// The redesign's menus (`.mi`, `.mh`): 30pt rows under a 26pt header.
    public static let menuRowHeight: CGFloat = 30
    public static let menuHeaderHeight: CGFloat = 26
    #else
    public static let menuRowHeight: CGFloat = 28
    public static let menuHeaderHeight: CGFloat = 24
    #endif
    public static let menuMaxRows = 8
    /// The slash menu (SlashMenu board) spans the composer card: 36pt rows with 12pt sides, the
    /// command in a column at least 150pt wide.
    #if os(macOS)
    public static let slashRowHeight: CGFloat = 30
    /// The board sets each description right after its command, not in a column.
    public static let slashNameWidth: CGFloat = 0
    #else
    public static let slashRowHeight: CGFloat = 36
    public static let slashNameWidth: CGFloat = 150
    #endif
    /// The model picker (ModelPicker board): 380pt, two-line 40pt rows, sections 4pt apart.
    #if os(macOS)
    /// The redesign's picker (GXModel): 360pt, a 38pt search row, 52pt rows (a check, the id over its levels, the context
    /// size), sections butted together, the list 6pt in from the card.
    public static let modelPickerWidth: CGFloat = 360
    public static let modelRowHeight: CGFloat = 52
    public static let modelSectionGap: CGFloat = 0
    public static let modelSearchHeight: CGFloat = 38
    public static let modelListInset: CGFloat = SH.Space.s
    /// The model id in mono (the board's 12.5).
    public static let modelIdSize: CGFloat = 12.5
    #else
    public static let modelPickerWidth: CGFloat = 380
    public static let modelRowHeight: CGFloat = 40
    public static let modelSectionGap: CGFloat = 4
    public static let modelSearchHeight: CGFloat = 30
    public static let modelListInset: CGFloat = SH.Space.xs
    public static let modelIdSize: CGFloat = 12.5
    #endif
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
public struct SHComposer<Above: View, Top: View, Leading: View, Field: View, Controls: View>: View {
    /// How the Mac lays the card out: the thread's one line (attach, the words, the controls), or New
    /// thread's words over the line.
    public enum Layout: Sendable { case inline, stacked }

    let isFocused: Bool
    let layout: Layout
    /// Something that shares the card above its line (the Mac's Up next): inside the card's shape, line and focus ring.
    let above: Above
    let joined: Bool
    let top: Top
    let leading: Leading
    let field: Field
    let controls: Controls

    /// `joined` says `above` draws something: the card then clips only what is below it, so a row lifted by a drag floats free.
    public init(isFocused: Bool, layout: Layout = .stacked, joined: Bool = false, @ViewBuilder above: () -> Above,
                @ViewBuilder top: () -> Top, @ViewBuilder leading: () -> Leading,
                @ViewBuilder field: () -> Field, @ViewBuilder controls: () -> Controls) {
        self.isFocused = isFocused
        self.layout = layout
        self.joined = joined
        self.above = above()
        self.top = top()
        self.leading = leading()
        self.field = field()
        self.controls = controls()
    }

    public var body: some View {
        #if os(macOS)
        mac
        #else
        touch
        #endif
    }

    /// The boards' `.cmp`: `bgRaised` at radius 14 on the `lift` shadow, attachments over one line.
    private var mac: some View {
        let shape = RoundedRectangle(cornerRadius: SHComposerMetrics.radius)
        let below = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: joined ? 0 : SHComposerMetrics.radius, bottomLeading: SHComposerMetrics.radius,
            bottomTrailing: SHComposerMetrics.radius, topTrailing: joined ? 0 : SHComposerMetrics.radius))
        return VStack(alignment: .leading, spacing: 0) {
            above
            VStack(alignment: .leading, spacing: 0) {
            chips
            switch layout {
            case .inline:
                HStack(alignment: .bottom, spacing: SHComposerMetrics.lineGap) {
                    leading.frame(height: SHComposerMetrics.lineHeight)
                    // One line of words sits centred in the 48pt line; more grow the card upward.
                    field
                        .padding(.vertical, (SHComposerMetrics.lineHeight - SHTextStyle.body.size * SHTextStyle.body.lineHeight) / 2)
                        .frame(maxWidth: .infinity, minHeight: SHComposerMetrics.lineHeight, alignment: .leading)
                    HStack(spacing: SH.Space.xxs) { controls }
                        .frame(height: SHComposerMetrics.lineHeight)
                }
                .padding(.horizontal, SHComposerMetrics.linePadding)
            case .stacked:
                field
                    .padding(EdgeInsets(top: SHComposerMetrics.stackedFieldPadding, leading: SHComposerMetrics.stackedFieldPadding,
                                        bottom: 0, trailing: SHComposerMetrics.stackedFieldPadding))
                    .frame(minHeight: SHComposerMetrics.stackedFieldMinHeight, alignment: .topLeading)
                HStack(spacing: SHComposerMetrics.lineGap) {
                    leading
                    HStack(spacing: SH.Space.xxs) { controls }
                }
                .padding(.horizontal, SHComposerMetrics.linePadding)
                .frame(height: SHComposerMetrics.lineHeight)
            }
            }
            // As the card eases to a new height (a question taking the field's place, attachments
            // arriving), what it holds is revealed by its edge rather than drawn outside it.
            .clipShape(below)
        }
        .modifier(SHComposerFocus(isFocused: isFocused))
        .shLift(shape)
    }

    private var chips: some View {
        Group(subviews: top) { subviews in
            if !subviews.isEmpty {
                // Chips wrap to more rows (design references are wide).
                SHFlowLayout(spacing: SH.Space.s, lineSpacing: SH.Space.s) { subviews }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.horizontal, SH.Space.l)
            }
        }
    }

    private var touch: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        return VStack(alignment: .leading, spacing: 0) {
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
            HStack(spacing: SH.Space.xxs) { leading; controls }
                .padding(EdgeInsets(top: SH.Space.xs, leading: SH.Space.s, bottom: SH.Space.s, trailing: SH.Space.s))
        }
        .background(sh.bgRaised, in: shape)
        // As the card eases to a new height (a question taking the field's place, attachments
        // arriving), what it holds is revealed by its edge rather than drawn outside it.
        .clipShape(shape)
        // The line and the ring fade with focus; keyed on focus alone, so they never lag the
        // card as it grows.
        .modifier(SHComposerFocus(isFocused: isFocused))
    }
}

/// The card's edge. On the Mac the boards' `.cmp`: one 1pt `lineStrong` line, the same focused or not, and no ring.
/// Elsewhere the line darkens and a `bgSelected` ring comes round the card while it holds the keyboard.
private struct SHComposerFocus: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        let sh = Color.sh
        #if canImport(AppKit)
        content
            .overlay {
                RoundedRectangle(cornerRadius: SHComposerMetrics.radius)
                    .strokeBorder(sh.lineStrong, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        #else
        content
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
        #endif
    }
}

extension SHComposer where Above == EmptyView {
    public init(isFocused: Bool, layout: Layout = .stacked, @ViewBuilder top: () -> Top, @ViewBuilder leading: () -> Leading,
                @ViewBuilder field: () -> Field, @ViewBuilder controls: () -> Controls) {
        self.init(isFocused: isFocused, layout: layout, above: { EmptyView() }, top: top, leading: leading, field: field, controls: controls)
    }
}

extension SHComposer where Above == EmptyView, Leading == EmptyView {
    public init(isFocused: Bool, layout: Layout = .stacked, @ViewBuilder top: () -> Top, @ViewBuilder field: () -> Field,
                @ViewBuilder controls: () -> Controls) {
        self.init(isFocused: isFocused, layout: layout, above: { EmptyView() }, top: top, leading: { EmptyView() }, field: field, controls: controls)
    }
}

extension SHComposer where Above == EmptyView, Top == EmptyView, Leading == EmptyView {
    public init(isFocused: Bool, layout: Layout = .stacked, @ViewBuilder field: () -> Field, @ViewBuilder controls: () -> Controls) {
        self.init(isFocused: isFocused, layout: layout, above: { EmptyView() }, top: { EmptyView() }, leading: { EmptyView() }, field: field, controls: controls)
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

    /// Send and Stop are two glyphs stacked in the circle and cross-faded by opacity, so a turn
    /// starting or ending blends the fill and the glyph in place, together. Not one image whose
    /// symbol name changes: that draws through RenderBox, which loads about 258 MB of accelerated
    /// drawing pool for 1.2 to 1.6 s at every turn start and end (stacked, the swap costs about
    /// 7 MB). A symbol replace would also run on SF Symbols' own, slower clock and leave an arrow
    /// on the red Stop fill for a moment.
    public var body: some View {
        let sh = Color.sh
        let send = mode == .send
        // The Mac draws the boards' Send and Stop: both on the ink fill, Send on `bgSelected` with a dim arrow while there is
        // nothing to send. The iPhone and iPad keep Stop on `failed` and a faded Send.
        #if os(macOS)
        let (stopFill, stopGlyph, arrow) = (sh.primary, sh.textOnPrimary, enabled ? sh.textOnPrimary : sh.textTertiary)
        #else
        let (stopFill, stopGlyph, arrow) = (sh.failed, sh.textOnFailed, sh.textOnPrimary)
        #endif
        Button(action: action) {
            ZStack {
                glyph("arrow.up", size: SHComposerMetrics.sendGlyph, color: arrow, shown: send)
                glyph("stop.fill", size: SHComposerMetrics.stopGlyph, color: stopGlyph, shown: !send)
            }
        }
        .buttonStyle(SHComposerActionStyle(fill: send ? sh.primary : stopFill))
        .disabled(!enabled)
        .background {
            Circle().inset(by: -SHComposerMetrics.focusRing).fill(sh.lanternTint)
                .opacity(ringed ? 1 : 0)
                .shAnimation(.hover, value: ringed)
        }
        .shAnimation(.content, value: send)
        .accessibilityLabel(send ? "Send" : "Stop")
    }

    private func glyph(_ symbol: String, size: CGFloat, color: Color, shown: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(true)
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
        #if os(macOS)
        // Nothing to send: the boards' `.send.off`, the selection fill under a dim arrow.
        let shown = enabled ? fill.mix(with: .black, by: pressed ? 0.1 : 0) : Color.sh.bgSelected
        let faded = 1.0
        #else
        let shown = fill.mix(with: .black, by: pressed ? 0.1 : 0)
        // Send brightens as soon as there is something to send.
        let faded = enabled ? 1 : 0.35
        #endif
        configuration.label
            .frame(width: SHComposerMetrics.actionSize, height: SHComposerMetrics.actionSize)
            .background(shown, in: Circle())
            .opacity(faded)
            .shAnimation(.hover, value: enabled)
            .shAnimation(.hover, value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .shFocusRingCircle()
            .shTouchTarget(height: SHComposerMetrics.actionSize, width: SHComposerMetrics.actionSize)
    }
}

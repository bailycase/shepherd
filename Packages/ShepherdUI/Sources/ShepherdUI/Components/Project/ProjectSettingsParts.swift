import SwiftUI
import CoreText

/// Every measure Project settings draws that no token already holds (ProjectLead-SettingsGeneral, -SpacesV2, -Memory,
/// -Automations), computed from the boards' exported markup in a browser at 1x (points are CSS pixels) and checked against the
/// four PNGs at 2px per point. A value that equals a token (the 12pt row sides, the 6pt tab gap, radius 12) is used from the
/// token at the call site and is not repeated here. These are scoped to Project settings: no global token changes.
public enum NWProjectSettingsMetrics {
    /// The column: 760pt, centered, 32pt in from the window's sides.
    public static let columnWidth: CGFloat = 760
    /// A board's 1pt line (the card border, the dividers, a field). Layout counts it: a card's rows start 1pt inside it.
    public static let line: CGFloat = 1

    // MARK: Tabs

    /// A tab's label box: 32pt tall, 8pt either side of the text, a 2pt `lantern` rule under the one shown (34pt in all),
    /// and the 1pt rail under every tab.
    public static let tabHeight: CGFloat = 32
    public static let tabRule: CGFloat = 2

    // MARK: Rows

    /// A row is at least 52pt, counting its own 1pt divider; 8pt above and below its text.
    public static let rowMinHeight: CGFloat = 52
    /// A popup draws in a 40pt slot: its 32pt control with 4pt above and below.
    public static let popupSlotMargin: CGFloat = 4
    /// A leading glyph (a folder, a bolt) in a 14pt box, 12pt before its text.
    public static let rowGlyphBox: CGFloat = 14
    public static let rowGlyphSize: CGFloat = 12

    // MARK: Popup

    /// Geist 13 in a 32pt control, 12pt before the value and 36pt after it, where the chevrons sit.
    public static let popupTrailing: CGFloat = 36
    /// The up-down chevrons: the board puts a 12pt glyph box at the top of a 25.28pt line box centered on the control, so the mark's
    /// middle sits 6.6pt above the control's middle and 16.6pt from its right edge (measured on the 2x board's Add a space…: a 7 x 9pt
    /// mark). The SF Symbol's own ink is 6.5 x 9.4pt, the one difference from the board's SVG.
    public static let chevronBox: CGFloat = 12
    public static let chevronTrailing: CGFloat = 10.45
    public static let chevronLift: CGFloat = 7
    public static let chevronSize: CGFloat = 10

    // MARK: Fields

    /// The Goal field: 320 x 36.75, 8pt above and below an 18.75pt line (12.5 on 1.5), 12pt in beside its 1pt line.
    public static let goalFieldWidth: CGFloat = 320
    public static let fieldHeight: CGFloat = 36.75
    public static let fieldLineHeight: CGFloat = 1.5
    /// The instructions editor: 149.25pt at least (seven of those lines inside the same padding).
    public static let editorMinHeight: CGFloat = 149.25
    /// The section label (PROJECT INSTRUCTIONS): micro mono on a 12.6pt line, 4pt in from the card, 6pt over it.
    public static let sectionLabelHeight: CGFloat = 12.6
    /// A linked space's path line: Geist Mono 10.5/400 on 1.4. A memory entry and an editor line: 12.5 on 1.45 and 1.5.
    public static let pathSize: CGFloat = 10.5
    public static let pathLineHeight: CGFloat = 1.4
    public static let memoryLineHeight: CGFloat = 1.45
    /// The text inside the editor starts 12pt in and 8 down from its line, as a field's does.
    public static let editorInsetX: CGFloat = 12
    public static let editorInsetY: CGFloat = 8
    /// `TextEditor` insets its text by AppKit's 5pt line-fragment padding; the board has none.
    public static let editorFragmentPadding: CGFloat = 5
    /// The footnote sits 5pt under the editor (the board's inline-block baseline gap) and then its own 6pt.
    public static let editorFootnoteGap: CGFloat = 5
    /// A pressed button sinks half a point, as the shared button does (`NWButtonStyle`).
    public static let pressOffset: CGFloat = 0.5
    /// The Delete button's line: `failed` 30% over the card's fill.
    public static let dangerLineShare: Double = 0.3
}

extension NWPalette {
    /// The Delete… button's line (ProjectLead-SettingsGeneral: #572d2e on #15171a): `failed` at 30% over `bgRaised`, mixed in
    /// device RGB the way the board's `color-mix` is, so it is exact in both appearances and every theme.
    @MainActor public var projectSettingsDangerLine: Color {
        failed.mix(with: bgRaised, by: 1 - NWProjectSettingsMetrics.dangerLineShare, in: .device)
    }
}

extension View {
    /// The Goal field's and the instructions editor's chrome: `bgSunken`, radius 8, a 1pt `lineStrong` line, the focus ring
    /// while focused.
    public func nwProjectSettingsField(focused: Bool = false) -> some View {
        background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .overlay {
                Color.clear
                    .nwBorder(Color.nw.lineStrong, radius: NW.Radius.m, width: NWProjectSettingsMetrics.line)
                    .nwFocusRing(focused, radius: NW.Radius.m)
                    .allowsHitTesting(false)
            }
    }
}

/// Delete… on a Project settings card (ProjectLead-SettingsGeneral): the Controls board's 28pt button at radius 6 with `failed`
/// text, the card's own fill and a `failed` 30% line; hover tints it `failedTint`, pressed `bgSelected`, disabled dims.
public struct NWProjectSettingsDangerStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DangerButton(configuration: configuration)
    }

    private struct DangerButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let nw = Color.nw
            let shape = RoundedRectangle(cornerRadius: NW.Radius.s)
            configuration.label
                .font(.nw(.ui))
                .foregroundStyle(nw.failed)
                .lineLimit(1)
                .padding(.horizontal, NW.Space.l - NW.Space.xxs)
                .frame(minHeight: NW.Height.controlM)
                .background(enabled && configuration.isPressed ? nw.bgSelected : hovering && enabled ? nw.failedTint : nw.bgRaised, in: shape)
                .nwBorder(nw.projectSettingsDangerLine, radius: NW.Radius.s, width: NWProjectSettingsMetrics.line)
                .offset(y: configuration.isPressed ? NWProjectSettingsMetrics.pressOffset : 0)
                .nwEnabledOpacity(enabled)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .nwFocusRing(radius: NW.Radius.s)
        }
    }
}

/// A section label of Project settings: the Foundations label on the board's own 12.6pt line, 4pt in, 6pt above what it labels.
public struct NWProjectSettingsLabel: View {
    let title: String
    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .nwSectionLabel()
            .lineLimit(1)
            .frame(height: NWProjectSettingsMetrics.sectionLabelHeight)
            .padding(.horizontal, NW.Space.xs)
            .padding(.bottom, NW.Space.s)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A tab of Project settings (General, Spaces, Memory, Automations): Geist 12.5/400 between 8pt either side, 32pt tall, with the
/// 2pt rule under it while `selected`. SwiftUI sizes a `Text` up to a whole point, which drifts the tab row 1pt per tab from the
/// board's browser layout (the rule under Automations began 2pt late), so the label's width is the line's exact typographic
/// width at the current text scale. The text keeps its own ideal width inside that frame (`fixedSize`), so it can never truncate.
public struct NWProjectSettingsTab: View {
    let title: String
    let selected: Bool

    public init(_ title: String, selected: Bool) {
        self.title = title
        self.selected = selected
    }

    @MainActor static func width(of title: String) -> CGFloat {
        let font = CTFontCreateWithName(NWFonts.postScriptName(mono: false, weight: .regular) as CFString,
                                        NWTextStyle.ui.size * ThemeStore.shared.textScale, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    public var body: some View {
        let M = NWProjectSettingsMetrics.self
        VStack(spacing: 0) {
            Text(title)
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(selected ? Color.nw.textPrimary : Color.nw.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: Self.width(of: title), alignment: .leading)
                .padding(.horizontal, NW.Space.m)
                .frame(height: M.tabHeight)
            Rectangle().fill(selected ? Color.nw.lantern : Color.clear).frame(height: M.tabRule)
        }
        .fixedSize()
    }
}

/// The popup of Project settings (a model, Threads at once, Hosts, Add a space…): a native `Menu` drawn as the boards'
/// 32pt control in a 40pt slot, sized to its value, with its chevrons where the board puts them.
public struct NWProjectSettingsPopup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWProjectSettingsMetrics.self
        let S = NWSettingsControlMetrics.self
        Menu(content: content) {
            Text(title)
                .font(.nwSans(S.textSize))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .padding(.leading, S.popupLeading)
                .padding(.trailing, M.popupTrailing)
                .frame(height: S.controlHeight)
                .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: S.radius))
                .overlay(alignment: .trailing) {
                    NWGlyph.popupChevrons.image
                        .font(.nwSans(M.chevronSize))
                        .foregroundStyle(nw.textTertiary)
                        .frame(width: M.chevronBox, height: M.chevronBox)
                        .padding(.trailing, M.chevronTrailing)
                        .offset(y: -M.chevronLift)
                        .accessibilityHidden(true)
                }
                .nwBorder(nw.lineStrong, radius: S.radius, width: M.line)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityValue(title)
        .padding(.vertical, M.popupSlotMargin)
    }
}

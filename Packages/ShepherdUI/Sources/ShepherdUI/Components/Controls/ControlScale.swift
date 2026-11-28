import SwiftUI

/// Which size of the shared controls a surface draws. The Settings boards draw their pages'
/// controls larger than the Controls board does (a 32pt button at radius 7 in Geist 13, a
/// segmented control on a filled track, a 180pt slider with an 18pt knob, 22pt keycaps), so a
/// Settings page sets `.shControlScale(.settings)` once and every Shepherd Design control inside it
/// takes that size. Everywhere else the Controls board's sizes hold.
public enum SHControlScale: Sendable {
    /// The Controls board.
    case standard
    /// The Settings boards' pages.
    case settings
    /// A form sheet opened from Settings (Add app, Edit hook, Add server): the Settings controls, but a field is 32pt at
    /// radius 8 and a popup is drawn as a field.
    case sheet
    /// The design Tweak pane (DZTweak): the Controls board's sizes, but its slider is a 4pt `bgSelected` track filled with ink under a
    /// 16pt card knob, and its switch is 26×16 (`SHTweakControlMetrics`). Only the slider and the switch differ.
    case tweak
}

extension SHControlScale {
    /// The Settings boards' controls: a page's or a sheet's.
    public var isSettings: Bool { self == .settings || self == .sheet }
}

extension EnvironmentValues {
    @Entry public var shControlScale: SHControlScale = .standard
}

extension View {
    /// Draws the Shepherd Design controls inside at `scale`'s sizes.
    public func shControlScale(_ scale: SHControlScale) -> some View {
        environment(\.shControlScale, scale)
    }
}

/// The design Tweak pane's slider and switch (DZTweak's `.gdz-sl` and `.tgl`), used at `SHControlScale.tweak`.
public enum SHTweakControlMetrics {
    public static let sliderTrack: CGFloat = 4
    public static let sliderKnob: CGFloat = 16
    /// The slider takes the room the label leaves; its value is 24pt wide, 10pt after it.
    public static let sliderValueWidth: CGFloat = 24
    public static let sliderValueGap: CGFloat = SH.Space.l - 2
    public static let valueSize: CGFloat = 12
    public static let switchWidth: CGFloat = 26
    public static let switchHeight: CGFloat = 16
    public static let switchKnob: CGFloat = 12
    public static let switchInset: CGFloat = SH.Space.xxs
}

/// The Settings boards' control measures (the Mac redesign boards, CSS points): text buttons and popups with
/// no line of their own, 26pt fields, a filled segmented track under a lifted card pill, a 120 × 4 slider with a
/// 16pt knob, a 26 × 16 switch, and shortcuts written as plain text.
public enum SHSettingsControlMetrics {
    /// A button or popup's hit height, radius `s`. The board draws only its words.
    public static let controlHeight: CGFloat = 26
    public static let radius: CGFloat = SH.Radius.s
    /// A row's controls: the `ui` size (13), the hints under it `caption`.
    public static let textSize: CGFloat = SHTextStyle.ui.size
    /// A button's hit area overhangs its words by this much; the words stay flush with the row's padding.
    public static let pillHeight: CGFloat = 28
    public static let pillPadding: CGFloat = 13
    public static let pillRadius: CGFloat = 14
    public static let buttonOverhang: CGFloat = SH.Space.s
    public static let buttonPadding: CGFloat = SH.Space.m
    /// A popup: the value, 5pt, then a small up-and-down chevron.
    public static let popupLeading: CGFloat = 0
    public static let popupTrailing: CGFloat = 0
    public static let popupGap: CGFloat = SH.Space.s - 1
    public static let popupChevronSize: CGFloat = 8
    /// Text fields: 26pt, 8pt side padding, a 1pt line, at least 200pt wide (a port 100).
    public static let fieldHeight: CGFloat = 26
    public static let fieldPadding: CGFloat = SH.Space.m
    public static let fieldTextSize: CGFloat = SHTextStyle.ui.size
    public static let fieldWidth: CGFloat = 200
    /// The search fields: radius 7 on a `bgHover` fill, 26pt (28 in the nav).
    public static let searchRadius: CGFloat = 7
    /// A form sheet's field: 32pt, radius 8, 10pt in.
    public static let sheetFieldHeight: CGFloat = 32
    public static let sheetFieldRadius: CGFloat = SH.Radius.m
    public static let sheetFieldPadding: CGFloat = 10
    public static let sheetMonoSize: CGFloat = 12
    public static let wideFieldWidth: CGFloat = 320
    public static let portFieldWidth: CGFloat = 100
    /// The segmented control: 22pt segments 10pt in, on a `bgSelected` track 2pt in at radius 8; the chosen
    /// segment is a card lifted at radius 6.
    public static let segmentHeight: CGFloat = 22
    public static let segmentPadding: CGFloat = 10
    public static let segmentTrackPadding: CGFloat = SH.Space.xxs
    public static let segmentTrackRadius: CGFloat = SH.Radius.m
    public static let segmentRadius: CGFloat = SH.Radius.s
    public static let segmentTextSize: CGFloat = 12.5
    /// The slider: a 120 × 4 track filled to the knob, a 16pt knob in a 1px line, its value 10pt after it.
    public static let sliderWidth: CGFloat = 120
    public static let sliderTrack: CGFloat = SH.Space.xs
    public static let sliderKnob: CGFloat = 16
    public static let sliderValueGap: CGFloat = 10
    /// The stepper: "−  5  +" in `textSecondary` around a 12pt-wide value, about 12pt between the marks.
    public static let stepperHeight: CGFloat = 26
    public static let stepperButtonWidth: CGFloat = 20
    public static let stepperValueWidth: CGFloat = 12
    public static let stepperGlyphSize: CGFloat = 11
    public static let stepperGap: CGFloat = SH.Space.xs
    /// The switch: 26 × 16, a 12pt knob 2pt in.
    public static let switchWidth: CGFloat = 26
    public static let switchHeight: CGFloat = 16
    public static let switchKnob: CGFloat = 12
    public static let switchInset: CGFloat = SH.Space.xxs
    /// Keycaps: mono `caption`, 2pt above and below, 6pt in, 1pt `lineStrong` border at radius
    /// `xs`, 4pt apart.
    public static let keycapVerticalPadding: CGFloat = SH.Space.xxs
    public static let keycapPadding: CGFloat = SH.Space.s
    public static let keycapRadius: CGFloat = SH.Radius.xs
    /// A keycap's mono (outside Settings): 10.5.
    public static let keycapTextSize: CGFloat = 10.5
    public static let keycapSpacing: CGFloat = SH.Space.xs
    /// A written shortcut's letter spacing (.04em at 13).
    public static let keycapTracking: CGFloat = 0.5
}

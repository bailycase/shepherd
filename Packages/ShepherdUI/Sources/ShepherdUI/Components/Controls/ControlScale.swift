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

/// The Settings boards' control measures, as the canvas renders them (a 30pt CSS box plus its
/// 1px lines is 32pt).
public enum SHSettingsControlMetrics {
    /// Buttons and popups: 26pt, radius `s`, `caption` text.
    public static let controlHeight: CGFloat = 26
    public static let radius: CGFloat = SH.Radius.s
    public static let textSize: CGFloat = SHTextStyle.caption.size
    public static let buttonPadding: CGFloat = SH.Space.m
    /// A popup: 8pt before the value, 8 after the chevron, 6 between.
    public static let popupLeading: CGFloat = SH.Space.m
    public static let popupTrailing: CGFloat = SH.Space.m
    public static let popupGap: CGFloat = SH.Space.s
    public static let popupChevronSize: CGFloat = 8
    /// Text fields: 30pt, 10pt side padding, 240pt wide (a port 100).
    public static let fieldHeight: CGFloat = 30
    public static let fieldPadding: CGFloat = 10
    public static let fieldTextSize: CGFloat = 12.5
    public static let fieldWidth: CGFloat = 240
    public static let portFieldWidth: CGFloat = 100
    /// The segmented control: 24pt segments 8pt in, `lineStrong` dividers inside a 1pt `lineStrong`
    /// border at radius `s`; the chosen one fills `bgSelected`.
    public static let segmentHeight: CGFloat = 24
    public static let segmentPadding: CGFloat = SH.Space.m
    public static let segmentTrackRadius: CGFloat = SH.Radius.s
    /// The Subagents editor's hand-drawn track keeps its lifted pill.
    public static let segmentTrackPadding: CGFloat = 3
    public static let segmentRadius: CGFloat = SH.Radius.s
    /// The slider: a 180 × 4 track, an 18pt knob inside a 1px line, its value 12pt after it.
    public static let sliderWidth: CGFloat = 140
    public static let sliderTrack: CGFloat = 3
    public static let sliderKnob: CGFloat = 14
    public static let sliderValueGap: CGFloat = SH.Space.m
    /// The stepper: 30pt tall, 30pt buttons around a 34pt mono 13 value.
    public static let stepperHeight: CGFloat = 30
    public static let stepperButtonWidth: CGFloat = 30
    public static let stepperValueWidth: CGFloat = 34
    public static let stepperGlyphSize: CGFloat = 11
    /// Keycaps: mono `caption`, 2pt above and below, 6pt in, 1pt `lineStrong` border at radius
    /// `xs`, 4pt apart.
    public static let keycapVerticalPadding: CGFloat = SH.Space.xxs
    public static let keycapPadding: CGFloat = SH.Space.s
    public static let keycapRadius: CGFloat = SH.Radius.xs
    public static let keycapTextSize: CGFloat = SHTextStyle.caption.size
    public static let keycapSpacing: CGFloat = SH.Space.xs
}

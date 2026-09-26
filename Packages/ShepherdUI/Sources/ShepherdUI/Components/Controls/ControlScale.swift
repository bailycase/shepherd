import SwiftUI

/// Which size of the shared controls a surface draws. The Settings boards draw their pages'
/// controls larger than the Controls board does (a 32pt button at radius 7 in Geist 13, a
/// segmented control on a filled track, a 180pt slider with an 18pt knob, 22pt keycaps), so a
/// Settings page sets `.nwControlScale(.settings)` once and every Night Watch control inside it
/// takes that size. Everywhere else the Controls board's sizes hold.
public enum NWControlScale: Sendable {
    /// The Controls board.
    case standard
    /// The Settings boards' pages.
    case settings
}

extension EnvironmentValues {
    @Entry public var nwControlScale: NWControlScale = .standard
}

extension View {
    /// Draws the Night Watch controls inside at `scale`'s sizes.
    public func nwControlScale(_ scale: NWControlScale) -> some View {
        environment(\.nwControlScale, scale)
    }
}

/// The Settings boards' control measures, as the canvas renders them (a 30pt CSS box plus its
/// 1px lines is 32pt).
public enum NWSettingsControlMetrics {
    /// Buttons and popups: 32pt, radius 7, Geist 13.
    public static let controlHeight: CGFloat = 32
    public static let radius: CGFloat = 7
    public static let textSize: CGFloat = 13
    public static let buttonPadding: CGFloat = 12
    /// A popup: 12pt before the value, 10 after the chevrons, 10 between.
    public static let popupLeading: CGFloat = 12
    public static let popupTrailing: CGFloat = 10
    public static let popupGap: CGFloat = 10
    /// Text fields: 30pt, 10pt side padding, 240pt wide (a port 100).
    public static let fieldHeight: CGFloat = 30
    public static let fieldPadding: CGFloat = 10
    public static let fieldTextSize: CGFloat = 12.5
    public static let fieldWidth: CGFloat = 240
    public static let portFieldWidth: CGFloat = 100
    /// The segmented control: 26pt segments 12pt in, 2pt apart on a 3pt-padded track at radius 8,
    /// the chosen one at radius 6.
    public static let segmentHeight: CGFloat = 26
    public static let segmentPadding: CGFloat = 12
    public static let segmentTrackPadding: CGFloat = 3
    public static let segmentTrackRadius: CGFloat = 8
    public static let segmentRadius: CGFloat = 6
    /// The slider: a 180 × 4 track, an 18pt knob inside a 1px line, its value 12pt after it.
    public static let sliderWidth: CGFloat = 180
    public static let sliderTrack: CGFloat = 4
    public static let sliderKnob: CGFloat = 20
    public static let sliderValueGap: CGFloat = 12
    /// The stepper: 30pt tall, 30pt buttons around a 34pt mono 13 value.
    public static let stepperHeight: CGFloat = 30
    public static let stepperButtonWidth: CGFloat = 30
    public static let stepperValueWidth: CGFloat = 34
    public static let stepperGlyphSize: CGFloat = 11
    /// Keycaps: 22pt, at least 22 wide, 6pt in, radius 5, mono 11.5 in `textPrimary`, 4pt apart.
    public static let keycapHeight: CGFloat = 22
    public static let keycapPadding: CGFloat = 6
    public static let keycapRadius: CGFloat = 5
    public static let keycapTextSize: CGFloat = 11.5
    public static let keycapSpacing: CGFloat = 4
}

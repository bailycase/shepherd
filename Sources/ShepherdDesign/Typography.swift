import SwiftUI

/// The type ramp. System faces at the spec's sizes: sans for prose and chrome, monospaced for
/// anything the agent touched (paths, commands, code, metadata). Scales with the text-size
/// setting.
@MainActor
public enum Fonts {
    private static var scale: CGFloat { ThemeStore.shared.textScale }

    public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .default)
    }

    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    /// 22/600 — sheet and page titles, empty states.
    public static var display: Font { sans(22, .semibold) }
    /// 15/600 — header thread title.
    public static var title: Font { sans(15, .semibold) }
    /// 15 ×1.6 — agent prose.
    public static var body: Font { sans(15) }
    /// 14 ×1.5 — user turns, the composer.
    public static var bodySmall: Font { sans(14) }
    /// 13.5/500 — settings row titles.
    public static var rowTitle: Font { sans(13.5, .medium) }
    /// 13/500 — sidebar rows, breadcrumb, buttons.
    public static var label: Font { sans(13, .medium) }
    public static var labelRegular: Font { sans(13) }
    public static var labelStrong: Font { sans(13, .semibold) }
    /// 12.5 — settings row descriptions.
    public static var description: Font { sans(12.5) }
    /// 12 — status pill, chips, captions.
    public static var caption: Font { sans(12) }
    public static var captionMedium: Font { sans(12, .medium) }
    /// 11/600 caps — section headings (apply with `.sectionStyle()`).
    public static var section: Font { sans(11, .semibold) }
    /// 10.5/600 caps — palette group headers, hunk headers.
    public static var sectionSmall: Font { sans(10.5, .semibold) }
    /// 12.5 mono — paths, commands, code.
    public static var code: Font { mono(12.5) }
    public static var codeMedium: Font { mono(12.5, .medium) }
    /// 12 mono ×1.55 — tool output, diff lines.
    public static var output: Font { mono(12) }
    /// 11 mono — timestamps, counts, durations.
    public static var micro: Font { mono(11) }
    public static var microMedium: Font { mono(11, .medium) }

    /// Extra leading (added to the font's own) that reaches the spec's line heights.
    public static var bodyLeading: CGFloat { 15 * scale * 0.6 - 3 }
    public static var bodySmallLeading: CGFloat { 14 * scale * 0.5 - 3 }
    public static var outputLeading: CGFloat { 12 * scale * 0.55 - 2 }
}

extension View {
    /// Uppercase, tracked, tertiary: the section heading treatment ("THIS MAC", "AUTOMATIONS").
    @MainActor
    public func sectionStyle(_ font: Font? = nil) -> some View {
        self.font(font ?? Fonts.section)
            .textCase(.uppercase)
            .tracking(0.66)
            .foregroundStyle(Tokens.textTertiary)
    }
}

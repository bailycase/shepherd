import SwiftUI
import ShepherdCore

/// Every color a view uses. Names follow the design handoff (`bg.canvas` → `bgCanvas`). Values
/// come from the selected theme and follow light/dark on their own; never hardcode a color in
/// a view.
///
/// Pairing rule: a semantic fill (`…Bg`) only ever carries its own `…Text`, and `…Text` only
/// sits on its `…Bg` or on `bgSurface`. The base semantic color is for dots, glyphs, spinners,
/// bars, and fills behind white-free labels, never body text.
@MainActor
public enum Tokens {
    private static var store: ThemeStore { .shared }

    // Backgrounds
    public static var bgCanvas: Color { store.color(\.bgCanvas) }
    public static var bgSurface: Color { store.color(\.bgSurface) }
    public static var bgRaised: Color { store.color(\.bgRaised) }
    public static var bgMuted: Color { store.color(\.bgMuted) }
    public static var bgBubble: Color { store.color(\.bgBubble) }
    public static var bgSelected: Color { store.color(\.bgSelected) }
    public static var bgHover: Color { store.color(\.bgHover) }
    public static var bgHoverStrong: Color { store.color(\.bgHoverStrong) }
    public static var bgTrack: Color { store.color(\.bgTrack) }

    // Borders
    public static var borderSubtle: Color { store.color(\.borderSubtle) }
    public static var border: Color { store.color(\.border) }
    public static var borderStrong: Color { store.color(\.borderStrong) }

    // Text
    public static var text: Color { store.color(\.text) }
    public static var textSecondary: Color { store.color(\.textSecondary) }
    public static var textTertiary: Color { store.color(\.textTertiary) }
    public static var textMuted: Color { store.color(\.textMuted) }
    public static var textDisabled: Color { store.color(\.textDisabled) }

    // Semantic
    public static var accent: Color { store.color(\.accent) }
    public static var accentText: Color { store.color(\.accentText) }
    public static var accentBg: Color { store.color(\.accentBg) }
    public static var success: Color { store.color(\.success) }
    public static var successText: Color { store.color(\.successText) }
    public static var successBg: Color { store.color(\.successBg) }
    public static var warning: Color { store.color(\.warning) }
    public static var warningText: Color { store.color(\.warningText) }
    public static var warningBg: Color { store.color(\.warningBg) }
    public static var danger: Color { store.color(\.danger) }
    public static var dangerText: Color { store.color(\.dangerText) }
    public static var dangerBg: Color { store.color(\.dangerBg) }
    public static var dotIdle: Color { store.color(\.dotIdle) }

    // Derived roles
    /// Primary buttons are the text color with the surface as their label.
    public static var primaryFill: Color { text }
    public static var primaryLabel: Color { bgSurface }
    /// The 3pt focus ring around a focused field or selected card.
    public static var focusRing: Color { accent.opacity(0.18) }
    /// Behind the command palette.
    public static let scrim = Color(lightRGBA: (0, 0, 0, 0.18), darkRGBA: (0, 0, 0, 0.45))
    /// The two shadows the design allows: the composer's and the segmented thumb's, plus the
    /// larger one under floating menus and the palette.
    public static let composerShadow = Color(lightRGBA: (0.11, 0.1, 0.1, 0.06), darkRGBA: (0, 0, 0, 0.35))
    public static let thumbShadow = Color(lightRGBA: (0.11, 0.1, 0.1, 0.12), darkRGBA: (0, 0, 0, 0.45))
    public static let menuShadow = Color(lightRGBA: (0.11, 0.1, 0.1, 0.14), darkRGBA: (0, 0, 0, 0.5))

    public static func syntax(_ role: KeyPath<SyntaxColors, String>) -> Color { store.syntax(role) }

    /// Sidebar status dot (spec §6): running is green ("alive"), a waiting agent warning,
    /// the open thread accent, everything else the idle grey.
    public static func statusDot(_ status: AgentStatus, isCurrent: Bool = false) -> Color {
        switch status {
        case .working: success
        case .blocked: warning
        case .idle, .done: isCurrent ? accent : dotIdle
        }
    }
}

import SwiftUI
import CoreText

/// The Shepherd Design type ramp (the redesign boards). SF Pro for prose and chrome, SF Mono for
/// anything the agent touched. Sizes are points and scale with Settings ▸ Appearance ▸ Text size;
/// on iOS they follow the phone and iPad boards' larger ramp and Dynamic Type (`relativeTo:`).
public enum SHTextStyle: Int, CaseIterable, Sendable {
    /// SF Pro 22/600/28: empty states, onboarding.
    case display
    /// SF Pro 13/600/18: thread and pane titles.
    case title
    /// SF Pro 13/600/18: card titles, section heads.
    case headline
    /// SF Pro 14/400/22: agent prose, bubbles.
    case body
    /// SF Pro 13/400/18: rows, buttons, controls.
    case ui
    /// SF Pro 12/400/17: secondary info.
    case caption
    /// SF Mono 12/400/1.5: code blocks, output.
    case code
    /// SF Mono 12/400/1.3: paths, commands, tool rows.
    case mono
    /// SF Mono 11/500/1.2: section labels (uppercase, via `.shSectionLabel()`).
    case micro

    public var size: CGFloat {
        #if os(iOS)
        // The phone and iPad boards' ramp: rows at 15, prose at 16, meta at 12.
        switch self {
        case .display: 28
        case .title: 16
        case .headline: 17
        case .body: 16
        case .ui: 15
        case .caption, .mono: 12
        case .code: 13
        case .micro: 11
        }
        #else
        switch self {
        case .display: 22
        case .title, .headline, .ui: 13
        case .body: 14
        case .caption, .mono, .code: 12
        case .micro: 11
        }
        #endif
    }

    public var weight: Font.Weight {
        switch self {
        case .display, .title, .headline: .semibold
        case .micro: .medium
        #if os(iOS)
        case .ui: .medium
        #else
        case .ui: .regular
        #endif
        case .body, .caption, .code, .mono: .regular
        }
    }

    /// Line height as a multiple of the size.
    public var lineHeight: CGFloat {
        #if os(iOS)
        switch self {
        case .display: 1.15
        case .title, .ui, .mono: 1.3
        case .headline, .caption: 1.35
        case .body: 1.5
        case .code: 1.55
        case .micro: 1.2
        }
        #else
        // The boards' line boxes: 28 on 22, 18 on 13, 22 on 14, 17 on 12.
        switch self {
        case .display: 28.0 / 22
        case .title, .headline, .ui: 18.0 / 13
        case .body: 22.0 / 14
        case .caption: 17.0 / 12
        case .code: 1.5
        case .mono: 1.3
        case .micro: 1.2
        }
        #endif
    }

    public var isMonospaced: Bool { self == .code || self == .mono || self == .micro }

    var dynamicTypeStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title: .title3
        case .headline: .headline
        case .body: .body
        case .ui: .callout
        case .caption: .caption
        case .code: .callout
        case .mono: .caption
        case .micro: .caption2
        }
    }
}

#if canImport(AppKit)
public typealias SHPlatformFont = NSFont
#else
public typealias SHPlatformFont = UIFont
#endif

/// The faces: SF Pro and SF Mono on the Mac, nothing to register or look up by name. The iPhone
/// and iPad client keeps the bundled Geist (SIL OFL, `Resources/Fonts/OFL.txt`) until its own
/// redesign, so custom fonts keep scaling with Dynamic Type there.
public enum SHFonts {
    #if os(macOS)
    public static let sansFamily = "SF Pro"
    public static let monoFamily = "SF Mono"
    #else
    public static let sansFamily = "Geist"
    public static let monoFamily = "Geist Mono"
    #endif
    /// The CSS stacks that reach the system faces in a web view (Mermaid, page overlays).
    public static let sansCSS = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    public static let monoCSS = "ui-monospace, SFMono-Regular, Menlo, monospace"

    /// Registers the bundled faces once (iOS); free, and a no-op on the Mac.
    public static func register() {
        #if !os(macOS)
        _ = registration
        #endif
    }

    /// The face for `mono` at `weight` and `size` points, as an AppKit or UIKit font.
    public static func platform(mono: Bool, weight: Font.Weight, size: CGFloat, italic: Bool = false) -> SHPlatformFont {
        #if os(macOS)
        let w = platformWeight(weight)
        let font: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: w) : .systemFont(ofSize: size, weight: w)
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        #else
        register()
        return UIFont(name: postScriptName(mono: mono, weight: weight, italic: italic), size: size)
            ?? (mono ? .monospacedSystemFont(ofSize: size, weight: platformWeight(weight)) : .systemFont(ofSize: size, weight: platformWeight(weight)))
        #endif
    }

    static func platformWeight(_ weight: Font.Weight) -> SHPlatformFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    /// The face's natural line height (ascent, descent, leading) at `size`.
    static func naturalLineHeight(mono: Bool, weight: Font.Weight, size: CGFloat, roundedUp: Bool = false) -> CGFloat {
        let ct = platform(mono: mono, weight: weight, size: size) as CTFont
        let parts = [CTFontGetAscent(ct), CTFontGetDescent(ct), CTFontGetLeading(ct)]
        return parts.reduce(0) { $0 + (roundedUp ? $1.rounded(.up) : $1) }
    }

    #if !os(macOS)
    private static let registration: Void = {
        guard let directory = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "otf" {
            // Already registered (a second bundle copy, or the faces are installed) is fine.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func postScriptName(mono: Bool, weight: Font.Weight, italic: Bool = false) -> String {
        let face: String = switch weight {
        case .medium: "Medium"
        case .semibold: "SemiBold"
        case .bold, .heavy, .black: "Bold"
        default: "Regular"
        }
        if mono { return "GeistMono-\(face)" }
        if italic { return face == "Regular" ? "Geist-Italic" : "Geist-\(face)Italic" }
        return "Geist-\(face)"
    }
    #endif
}

/// How a thread's prose and bubbles are set: the thread's own ramp, or one step smaller in a
/// transcript beside it (the subagent inspector: the Subagents mock sets it a point under the
/// thread). Components that set prose read it from the environment (`shProseSize`).
public enum SHProseSize: Int, CaseIterable, Sendable {
    case regular, small

    /// Points under the ramp: one step, `.body` down to the `.ui` size.
    public var step: CGFloat { self == .small ? SHTextStyle.body.size - SHTextStyle.ui.size : 0 }
}

extension EnvironmentValues {
    /// The prose size for thread components under this view.
    @Entry public var shProseSize: SHProseSize = .regular
}

/// Every text style at one text scale, at each prose size, built once per scale change.
public final class SHTypeRamp: Sendable {
    public let scale: CGFloat
    /// Indexed by prose size, then style.
    private let fonts: [[Font]]
    private let spacing: [[CGFloat]]

    init(scale: CGFloat) {
        self.scale = scale
        var fonts: [[Font]] = []
        var spacing: [[CGFloat]] = []
        for proseSize in SHProseSize.allCases {
            var sizeFonts: [Font] = []
            var sizeSpacing: [CGFloat] = []
            for style in SHTextStyle.allCases {
                let size = (style.size - proseSize.step) * scale
                sizeFonts.append(Font.shSystem(size, weight: style.weight, mono: style.isMonospaced, relativeTo: style.dynamicTypeStyle))
                // Extra leading that takes the face's natural line height to the ramp's.
                let natural = SHFonts.naturalLineHeight(mono: style.isMonospaced, weight: style.weight, size: size)
                sizeSpacing.append(max(0, (size * style.lineHeight - natural).rounded(.toNearestOrEven)))
            }
            fonts.append(sizeFonts)
            spacing.append(sizeSpacing)
        }
        self.fonts = fonts
        self.spacing = spacing
    }

    public func font(_ style: SHTextStyle, size: SHProseSize = .regular) -> Font { fonts[size.rawValue][style.rawValue] }
    /// Extra leading (`.lineSpacing`) that reaches the style's line height.
    public func lineSpacing(_ style: SHTextStyle, size: SHProseSize = .regular) -> CGFloat { spacing[size.rawValue][style.rawValue] }
}

extension Font {
    /// A Shepherd Design text style: `.font(.sh(.body))`. Pass `weight` for the rare emphasis the
    /// ramp does not carry (a bold path segment, a medium count), and `size` for prose set in a
    /// side transcript.
    @MainActor public static func sh(_ style: SHTextStyle, weight: Font.Weight? = nil, size: SHProseSize = .regular) -> Font {
        guard let weight, weight != style.weight else { return ThemeStore.shared.typeRamp.font(style, size: size) }
        return .shFace(style.size - size.step, weight: weight, mono: style.isMonospaced, relativeTo: style.dynamicTypeStyle)
    }

    /// A one-off SF Pro size the ramp does not name (the empty-state title, a palette search
    /// field). Prefer a ramp style.
    @MainActor public static func shSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .shFace(size, weight: weight, mono: false, relativeTo: .body)
    }

    /// A one-off SF Mono size the ramp does not name. Prefer a ramp style.
    @MainActor public static func shMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .shFace(size, weight: weight, mono: true, relativeTo: .body)
    }

    @MainActor private static func shFace(_ size: CGFloat, weight: Font.Weight, mono: Bool, relativeTo: Font.TextStyle) -> Font {
        shSystem(size * ThemeStore.shared.textScale, weight: weight, mono: mono, relativeTo: relativeTo)
    }

    /// The system face at `points`: fixed on the Mac (our text scale already sets the size), and
    /// scaled with Dynamic Type relative to `relativeTo` on iOS.
    static func shSystem(_ points: CGFloat, weight: Font.Weight, mono: Bool, relativeTo: Font.TextStyle) -> Font {
        #if os(macOS)
        return .system(size: points, weight: weight, design: mono ? .monospaced : .default)
        #else
        SHFonts.register()
        return .custom(SHFonts.postScriptName(mono: mono, weight: weight), size: points, relativeTo: relativeTo)
        #endif
    }
}

extension SHTextStyle {
    /// Extra leading at the current text scale.
    @MainActor public var lineSpacing: CGFloat { ThemeStore.shared.typeRamp.lineSpacing(self) }

    /// Extra leading at the current text scale and `size`.
    @MainActor public func lineSpacing(_ size: SHProseSize) -> CGFloat { ThemeStore.shared.typeRamp.lineSpacing(self, size: size) }
}

extension View {
    /// A text style with its line height: the font plus the extra leading that reaches it. Use
    /// for text that wraps; `.font(.sh(_:))` alone is enough for single lines.
    @MainActor public func shText(_ style: SHTextStyle, size: SHProseSize = .regular) -> some View {
        font(.sh(style, size: size)).lineSpacing(style.lineSpacing(size))
    }

    /// A one-off size the ramp does not name, set at its own line height (a Settings description
    /// at 12.5/1.45, a footnote at 12/1.5): the font plus the extra leading that reaches it.
    @MainActor public func shText(size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false, lineHeight: CGFloat) -> some View {
        font(mono ? .shMono(size, weight) : .shSans(size, weight))
            .lineSpacing(SHLineSpacing.extra(size: size, weight: weight, mono: mono, lineHeight: lineHeight))
    }

    /// The Settings boards' section label ("BUNDLED EXTENSIONS", "HOW THE AGENT READS THEM"):
    /// SF Pro 11/600, uppercase, tracked 6%, in `textSecondary`. `table` is a list's column header
    /// and a detail's label (Skill, Source, Use it): 10.5 in `textTertiary`.
    @MainActor public func shSettingsLabel(table: Bool = false) -> some View {
        let size: CGFloat = table ? 10.5 : 11
        return font(.shSans(size, .semibold))
            .textCase(.uppercase)
            .tracking(size * 0.06)
            .foregroundStyle(table ? Color.sh.textTertiary : Color.sh.textSecondary)
    }

    /// The section label treatment ("THIS MAC", "AUTOMATIONS"): micro mono, uppercase, tracked 6%
    /// (the Foundations board's 0.06em), tertiary.
    @MainActor public func shSectionLabel() -> some View {
        font(.sh(.micro))
            .textCase(.uppercase)
            .tracking(SHTextStyle.micro.size * 0.06)
            .foregroundStyle(.sh.textTertiary)
    }
}

/// Extra leading for the one-off sizes `shText(size:weight:mono:lineHeight:)` sets, measured once
/// per scaled size: building a CoreText font on every render would be too slow.
@MainActor enum SHLineSpacing {
    private struct Key: Hashable {
        let size: CGFloat
        let weight: Font.Weight
        let mono: Bool
        let lineHeight: CGFloat
    }

    private static var cache: [Key: CGFloat] = [:]

    /// Half of the leading CSS adds above and below a line of `lineHeight` (a multiple of the size): fractional, as CSS's is, where
    /// `extra` rounds to a whole point (13.5pt at 1.6 is 21.6, and a line the text system sets at 18 needs 1.8 each side, not 2).
    static func halfLeading(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let scaled = size * ThemeStore.shared.textScale
        let line = SHFonts.naturalLineHeight(mono: false, weight: .regular, size: scaled, roundedUp: true)
        return max(0, (scaled * lineHeight - line) / 2)
    }

    static func extra(size: CGFloat, weight: Font.Weight, mono: Bool, lineHeight: CGFloat) -> CGFloat {
        let scaled = size * ThemeStore.shared.textScale
        let key = Key(size: scaled, weight: weight, mono: mono, lineHeight: lineHeight)
        if let cached = cache[key] { return cached }
        let natural = SHFonts.naturalLineHeight(mono: mono, weight: weight, size: scaled)
        let extra = max(0, (scaled * lineHeight - natural).rounded(.toNearestOrEven))
        cache[key] = extra
        return extra
    }
}

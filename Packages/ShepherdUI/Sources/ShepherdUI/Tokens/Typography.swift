import SwiftUI
import CoreText

/// The Night Watch type ramp (Foundations board). Geist for prose and chrome, Geist Mono for
/// anything the agent touched. Sizes are points and scale with Settings ▸ Appearance ▸ Text size;
/// on iOS they follow the phone and iPad boards' larger ramp and Dynamic Type (`relativeTo:`).
public enum NWTextStyle: Int, CaseIterable, Sendable {
    /// Geist 28/600/1.15: empty states, onboarding.
    case display
    /// Geist 15/600/1.3: thread and pane titles.
    case title
    /// Geist 13.5/600/1.35: card titles, section heads.
    case headline
    /// Geist 13.5/400/1.6: agent prose, bubbles.
    case body
    /// Geist 12.5/500/1.3: rows, buttons, controls.
    case ui
    /// Geist 11.5/400/1.35: secondary info.
    case caption
    /// Geist Mono 12/400/1.55: code blocks, output.
    case code
    /// Geist Mono 11.5/400/1.3: paths, commands, tool rows.
    case mono
    /// Geist Mono 10.5/500/1.2: section labels (uppercase, via `.nwSectionLabel()`).
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
        case .display: 28
        case .title: 15
        case .headline, .body: 13.5
        case .ui: 12.5
        case .caption, .mono: 11.5
        case .code: 12
        case .micro: 10.5
        }
        #endif
    }

    public var weight: Font.Weight {
        switch self {
        case .display, .title, .headline: .semibold
        case .ui, .micro: .medium
        case .body, .caption, .code, .mono: .regular
        }
    }

    /// Line height as a multiple of the size.
    public var lineHeight: CGFloat {
        switch self {
        case .display: 1.15
        case .title, .ui, .mono: 1.3
        case .headline, .caption: 1.35
        #if os(iOS)
        case .body: 1.5
        #else
        case .body: 1.6
        #endif
        case .code: 1.55
        case .micro: 1.2
        }
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

/// The bundled faces (SIL OFL, `Resources/Fonts/OFL.txt`), registered for the process from the
/// package bundle: no Info.plist entry needed.
public enum NWFonts {
    public static let sansFamily = "Geist"
    public static let monoFamily = "Geist Mono"

    /// Registers every bundled face once; later calls are free. `ThemeStore` calls it, so any
    /// token read registers the fonts, and the app calls it at launch.
    public static func register() { _ = registration }

    /// Whether the faces are available to CoreText (registered from the bundle, or installed).
    public static var isAvailable: Bool {
        register()
        let font = CTFontCreateWithName(postScriptName(mono: false, weight: .regular) as CFString, 12, nil)
        return (CTFontCopyFamilyName(font) as String) == sansFamily
    }

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
}

/// How a thread's prose and bubbles are set: the thread's own ramp, or one step smaller in a
/// transcript beside it (the subagent inspector: the Subagents mock sets it a point under the
/// thread). Components that set prose read it from the environment (`nwProseSize`).
public enum NWProseSize: Int, CaseIterable, Sendable {
    case regular, small

    /// Points under the ramp: one step, `.body` down to the `.ui` size.
    public var step: CGFloat { self == .small ? NWTextStyle.body.size - NWTextStyle.ui.size : 0 }
}

extension EnvironmentValues {
    /// The prose size for thread components under this view.
    @Entry public var nwProseSize: NWProseSize = .regular
}

/// Every text style at one text scale, at each prose size, built once per scale change.
public final class NWTypeRamp: Sendable {
    public let scale: CGFloat
    /// Indexed by prose size, then style.
    private let fonts: [[Font]]
    private let spacing: [[CGFloat]]

    init(scale: CGFloat) {
        self.scale = scale
        var fonts: [[Font]] = []
        var spacing: [[CGFloat]] = []
        for proseSize in NWProseSize.allCases {
            var sizeFonts: [Font] = []
            var sizeSpacing: [CGFloat] = []
            for style in NWTextStyle.allCases {
                let size = (style.size - proseSize.step) * scale
                let name = NWFonts.postScriptName(mono: style.isMonospaced, weight: style.weight)
                sizeFonts.append(.custom(name, size: size, relativeTo: style.dynamicTypeStyle))
                // Extra leading that takes the face's natural line height to the ramp's.
                let ct = CTFontCreateWithName(name as CFString, size, nil)
                let natural = CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
                sizeSpacing.append(max(0, (size * style.lineHeight - natural).rounded(.toNearestOrEven)))
            }
            fonts.append(sizeFonts)
            spacing.append(sizeSpacing)
        }
        self.fonts = fonts
        self.spacing = spacing
    }

    public func font(_ style: NWTextStyle, size: NWProseSize = .regular) -> Font { fonts[size.rawValue][style.rawValue] }
    /// Extra leading (`.lineSpacing`) that reaches the style's line height.
    public func lineSpacing(_ style: NWTextStyle, size: NWProseSize = .regular) -> CGFloat { spacing[size.rawValue][style.rawValue] }
}

extension Font {
    /// A Night Watch text style: `.font(.nw(.body))`. Pass `weight` for the rare emphasis the
    /// ramp does not carry (a bold path segment, a medium count), and `size` for prose set in a
    /// side transcript.
    @MainActor public static func nw(_ style: NWTextStyle, weight: Font.Weight? = nil, size: NWProseSize = .regular) -> Font {
        guard let weight, weight != style.weight else { return ThemeStore.shared.typeRamp.font(style, size: size) }
        return .nwFace(style.size - size.step, weight: weight, mono: style.isMonospaced, relativeTo: style.dynamicTypeStyle)
    }

    /// A one-off Geist size the ramp does not name (the empty-state title, a palette search
    /// field). Prefer a ramp style.
    @MainActor public static func nwSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .nwFace(size, weight: weight, mono: false, relativeTo: .body)
    }

    /// A one-off Geist Mono size the ramp does not name. Prefer a ramp style.
    @MainActor public static func nwMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .nwFace(size, weight: weight, mono: true, relativeTo: .body)
    }

    @MainActor private static func nwFace(_ size: CGFloat, weight: Font.Weight, mono: Bool, relativeTo: Font.TextStyle) -> Font {
        .custom(NWFonts.postScriptName(mono: mono, weight: weight), size: size * ThemeStore.shared.textScale, relativeTo: relativeTo)
    }
}

extension NWTextStyle {
    /// Extra leading at the current text scale.
    @MainActor public var lineSpacing: CGFloat { ThemeStore.shared.typeRamp.lineSpacing(self) }

    /// Extra leading at the current text scale and `size`.
    @MainActor public func lineSpacing(_ size: NWProseSize) -> CGFloat { ThemeStore.shared.typeRamp.lineSpacing(self, size: size) }
}

extension View {
    /// A text style with its line height: the font plus the extra leading that reaches it. Use
    /// for text that wraps; `.font(.nw(_:))` alone is enough for single lines.
    @MainActor public func nwText(_ style: NWTextStyle, size: NWProseSize = .regular) -> some View {
        font(.nw(style, size: size)).lineSpacing(style.lineSpacing(size))
    }

    /// A one-off size the ramp does not name, set at its own line height (a Settings description
    /// at 12.5/1.45, a footnote at 12/1.5): the font plus the extra leading that reaches it.
    @MainActor public func nwText(size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false, lineHeight: CGFloat) -> some View {
        font(mono ? .nwMono(size, weight) : .nwSans(size, weight))
            .lineSpacing(NWLineSpacing.extra(size: size, weight: weight, mono: mono, lineHeight: lineHeight))
    }

    /// The section label treatment ("THIS MAC", "AUTOMATIONS"): micro mono, uppercase, tracked,
    /// tertiary.
    @MainActor public func nwSectionLabel() -> some View {
        font(.nw(.micro))
            .textCase(.uppercase)
            .tracking(NWTextStyle.micro.size * 0.05)
            .foregroundStyle(.nw.textTertiary)
    }
}

/// Extra leading for the one-off sizes `nwText(size:weight:mono:lineHeight:)` sets, measured once
/// per scaled size: building a CoreText font on every render would be too slow.
@MainActor enum NWLineSpacing {
    private struct Key: Hashable {
        let size: CGFloat
        let weight: Font.Weight
        let mono: Bool
        let lineHeight: CGFloat
    }

    private static var cache: [Key: CGFloat] = [:]

    static func extra(size: CGFloat, weight: Font.Weight, mono: Bool, lineHeight: CGFloat) -> CGFloat {
        let scaled = size * ThemeStore.shared.textScale
        let key = Key(size: scaled, weight: weight, mono: mono, lineHeight: lineHeight)
        if let cached = cache[key] { return cached }
        let ct = CTFontCreateWithName(NWFonts.postScriptName(mono: mono, weight: weight) as CFString, scaled, nil)
        let natural = CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
        let extra = max(0, (scaled * lineHeight - natural).rounded(.toNearestOrEven))
        cache[key] = extra
        return extra
    }
}

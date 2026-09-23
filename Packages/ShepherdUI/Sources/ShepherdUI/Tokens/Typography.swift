import SwiftUI
import CoreText

/// The Night Watch type ramp (Foundations board). Geist for prose and chrome, Geist Mono for
/// anything the agent touched. Sizes are points and scale with Settings ▸ Appearance ▸ Text size;
/// on iOS they also follow Dynamic Type (`relativeTo:`).
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
        switch self {
        case .display: 28
        case .title: 15
        case .headline, .body: 13.5
        case .ui: 12.5
        case .caption, .mono: 11.5
        case .code: 12
        case .micro: 10.5
        }
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
        case .body: 1.6
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

/// Every text style at one text scale, built once per scale change.
public final class NWTypeRamp: Sendable {
    public let scale: CGFloat
    private let fonts: [Font]
    private let spacing: [CGFloat]

    init(scale: CGFloat) {
        self.scale = scale
        var fonts: [Font] = []
        var spacing: [CGFloat] = []
        for style in NWTextStyle.allCases {
            let size = style.size * scale
            let name = NWFonts.postScriptName(mono: style.isMonospaced, weight: style.weight)
            fonts.append(.custom(name, size: size, relativeTo: style.dynamicTypeStyle))
            // Extra leading that takes the face's natural line height to the ramp's.
            let ct = CTFontCreateWithName(name as CFString, size, nil)
            let natural = CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
            spacing.append(max(0, (size * style.lineHeight - natural).rounded(.toNearestOrEven)))
        }
        self.fonts = fonts
        self.spacing = spacing
    }

    public func font(_ style: NWTextStyle) -> Font { fonts[style.rawValue] }
    /// Extra leading (`.lineSpacing`) that reaches the style's line height.
    public func lineSpacing(_ style: NWTextStyle) -> CGFloat { spacing[style.rawValue] }
}

extension Font {
    /// A Night Watch text style: `.font(.nw(.body))`. Pass `weight` for the rare emphasis the
    /// ramp does not carry (a bold path segment, a medium count).
    @MainActor public static func nw(_ style: NWTextStyle, weight: Font.Weight? = nil) -> Font {
        guard let weight, weight != style.weight else { return ThemeStore.shared.typeRamp.font(style) }
        return .nwFace(style.size, weight: weight, mono: style.isMonospaced, relativeTo: style.dynamicTypeStyle)
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
}

extension View {
    /// A text style with its line height: the font plus the extra leading that reaches it. Use
    /// for text that wraps; `.font(.nw(_:))` alone is enough for single lines.
    @MainActor public func nwText(_ style: NWTextStyle) -> some View {
        font(.nw(style)).lineSpacing(style.lineSpacing)
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

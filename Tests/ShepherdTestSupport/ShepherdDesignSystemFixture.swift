import Foundation
import SwiftUI
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

/// A synthetic built-in system for reference-page tests and previews only.
/// The app no longer ships or registers a Shepherd Design design system.
public enum ShepherdDesignSystem {
    public static let namespace = "shepherd-design"
    public static let title = "Shepherd Design"

    public static func tokens(_ theme: ThemeDefinition = .shepherdDesign) -> DesignSystemTokens {
        var tokens = DesignSystemTokens(name: title, namespace: namespace)
        tokens.colors = roles(theme.light.colors, theme.dark.colors, prefix: "")
            + roles(theme.light.syntax, theme.dark.syntax, prefix: "syn-")
        tokens.type = SHTextStyle.allCases.map { style in
            DesignSystemTokens.TypeStyle(
                name: "\(style)", size: Double(style.size), weight: weight(style.weight), lineHeight: Double(style.lineHeight),
                family: style.isMonospaced ? SHFonts.monoFamily : SHFonts.sansFamily,
                transform: style == .micro ? "uppercase" : nil)
        }
        tokens.spacing = [
            ("xxs", SH.Space.xxs), ("xs", SH.Space.xs), ("s", SH.Space.s), ("m", SH.Space.m), ("l", SH.Space.l),
            ("xl", SH.Space.xl), ("xxl", SH.Space.xxl), ("xxxl", SH.Space.xxxl),
        ].map { DesignSystemTokens.Length(name: "--space-\($0.0)", px: Double($0.1)) }
        tokens.radii = [("xs", SH.Radius.xs), ("s", SH.Radius.s), ("m", SH.Radius.m), ("l", SH.Radius.l)]
            .map { DesignSystemTokens.Length(name: "--radius-\($0.0)", px: Double($0.1)) }
        tokens.fonts = [
            DesignSystemTokens.Font(name: "sans", family: SHFonts.sansFamily, fallback: "system-ui, -apple-system, sans-serif"),
            DesignSystemTokens.Font(name: "mono", family: SHFonts.monoFamily, fallback: "ui-monospace, SFMono-Regular, Menlo, monospace"),
        ]
        return tokens
    }

    /// Each role of a variant's colors as a token: its name in kebab case (`bgBase` →
    /// `--bg-base`), the light value, and the dark one.
    private static func roles<T: Encodable>(_ light: T, _ dark: T, prefix: String) -> [DesignSystemTokens.Color] {
        let lightValues = values(light), darkValues = values(dark)
        return lightValues.map { role, value in
            DesignSystemTokens.Color(name: "--" + prefix + kebab(role), value: value, dark: darkValues.first { $0.0 == role }?.1)
        }
    }

    /// A struct's string properties in declaration order.
    private static func values<T>(_ value: T) -> [(String, String)] {
        Mirror(reflecting: value).children.compactMap { child in
            guard let label = child.label, let text = child.value as? String else { return nil }
            return (label, text)
        }
    }

    public static func kebab(_ name: String) -> String {
        var out = ""
        for character in name {
            if character.isUppercase {
                out += "-" + character.lowercased()
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func weight(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    public static func readme(_ tokens: DesignSystemTokens) -> String {
        """
        # Shepherd Design

        Shepherd's own design system, generated from the app's tokens: \(tokens.colors.count) colors (every role, light \
        and dark), \(tokens.type.count) type styles, \(tokens.spacing.count) spacing steps and \(tokens.radii.count) radii.

        ## Consuming this system

        Namespace: `shepherd-design`. It has no component bundle: build components as markup from its tokens.

        - Link its variables after the `support.js` line: `<link rel="stylesheet" href="ds/shepherd-design/tokens.css">`.
        - Colors are `var(--bg-window)`, `var(--text-primary)`, `var(--lantern)`, `var(--running)` and the other roles;
          code colors are `var(--syn-keyword)` and the rest.
        - The dark variant is opt-in: put `data-theme="dark"` on the board's root element.
        - Spacing is `var(--space-xxs)` to `var(--space-xxxl)` (2 to 32px on a 4px grid), radii `var(--radius-xs)` to
          `var(--radius-l)`.
        - Type is Geist for prose and chrome and Geist Mono for anything an agent touched, from Google Fonts. Sizes are
          `var(--text-<style>-size)` with `-weight` and `-line-height` beside them.
        """ + "\n"
    }

    public static func builtIn(_ theme: ThemeDefinition = .shepherdDesign) -> DesignSystemStore.BuiltIn {
        let tokens = tokens(theme)
        var files: [String: Data] = [
            DesignSystemFile.stylesheet: Data(tokens.css().utf8),
            DesignSystemFile.readme: Data(readme(tokens).utf8),
        ]
        files[DesignSystemFile.tokens] = (try? tokens.encoded()) ?? Data()
        return DesignSystemStore.BuiltIn(
            info: DesignSystemInfo(namespace: namespace, title: title, revision: 1, createdAt: 0), files: files)
    }
}

import Foundation
import SwiftUI
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

/// Night Watch as a built-in design system (docs/designs.md › Design systems): generated from
/// ShepherdUI's own tokens, so a design can be drawn in Shepherd's look. Every `ThemeColors`
/// and `SyntaxColors` role in both variants, the type ramp, the space and radius scales, and
/// the two faces. It is read-only and never synced; the app hands it to the server at launch.
enum NightWatchSystem {
    static let namespace = "night-watch"
    static let title = "Night Watch"

    static func tokens(_ theme: ThemeDefinition = .nightWatch) -> DesignSystemTokens {
        var tokens = DesignSystemTokens(name: title, namespace: namespace)
        tokens.colors = roles(theme.light.colors, theme.dark.colors, prefix: "")
            + roles(theme.light.syntax, theme.dark.syntax, prefix: "syn-")
        tokens.type = NWTextStyle.allCases.map { style in
            DesignSystemTokens.TypeStyle(
                name: "\(style)", size: Double(style.size), weight: weight(style.weight), lineHeight: Double(style.lineHeight),
                family: style.isMonospaced ? NWFonts.monoFamily : NWFonts.sansFamily,
                transform: style == .micro ? "uppercase" : nil)
        }
        tokens.spacing = [
            ("xxs", NW.Space.xxs), ("xs", NW.Space.xs), ("s", NW.Space.s), ("m", NW.Space.m), ("l", NW.Space.l),
            ("xl", NW.Space.xl), ("xxl", NW.Space.xxl), ("xxxl", NW.Space.xxxl),
        ].map { DesignSystemTokens.Length(name: "--space-\($0.0)", px: Double($0.1)) }
        tokens.radii = [("xs", NW.Radius.xs), ("s", NW.Radius.s), ("m", NW.Radius.m), ("l", NW.Radius.l)]
            .map { DesignSystemTokens.Length(name: "--radius-\($0.0)", px: Double($0.1)) }
        tokens.fonts = [
            DesignSystemTokens.Font(name: "sans", family: NWFonts.sansFamily, fallback: "system-ui, -apple-system, sans-serif"),
            DesignSystemTokens.Font(name: "mono", family: NWFonts.monoFamily, fallback: "ui-monospace, SFMono-Regular, Menlo, monospace"),
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

    static func kebab(_ name: String) -> String {
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

    static func readme(_ tokens: DesignSystemTokens) -> String {
        """
        # Night Watch

        Shepherd's own design system, generated from the app's tokens: \(tokens.colors.count) colors (every role, light \
        and dark), \(tokens.type.count) type styles, \(tokens.spacing.count) spacing steps and \(tokens.radii.count) radii.

        ## Consuming this system

        Namespace: `night-watch`. It has no component bundle: build components as markup from its tokens.

        - Link its variables after the `support.js` line: `<link rel="stylesheet" href="ds/night-watch/tokens.css">`.
        - Colors are `var(--bg-window)`, `var(--text-primary)`, `var(--lantern)`, `var(--running)` and the other roles;
          code colors are `var(--syn-keyword)` and the rest.
        - The dark variant is opt-in: put `data-theme="dark"` on the board's root element.
        - Spacing is `var(--space-xxs)` to `var(--space-xxxl)` (2 to 32px on a 4px grid), radii `var(--radius-xs)` to
          `var(--radius-l)`.
        - Type is Geist for prose and chrome and Geist Mono for anything an agent touched, from Google Fonts. Sizes are
          `var(--text-<style>-size)` with `-weight` and `-line-height` beside them.
        """ + "\n"
    }

    static func builtIn(_ theme: ThemeDefinition = .nightWatch) -> DesignSystemStore.BuiltIn {
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

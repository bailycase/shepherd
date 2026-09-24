import Testing
@testable import ShepherdUI

/// WCAG contrast for every built-in variant: 4.5:1 for text, 3:1 for dots, glyphs, and bars.
///
/// Night Watch's colors are the design's. Where a pair the board uses as text (or a state mark)
/// falls short, it is listed in `exceptions` with its measured ratio rather than recolored. The
/// test keeps that list honest: an exception must still be measured at its ratio and still fall
/// short, so a color change forces the list to be revisited.
@Suite("Theme contrast (WCAG)")
struct ThemeContrastTests {
    typealias Role = Variant.Role

    struct Pair {
        let name: String
        let text: Role
        let fill: Role
        /// What a translucent fill is painted over.
        let base: Role
        let minimum: Double
    }

    static let text = 4.5
    static let mark = 3.0

    static var pairs: [Pair] {
        var pairs: [Pair] = []
        let surfaces: [(String, Role)] = [("bgBase", \.bgBase), ("bgWindow", \.bgWindow), ("bgRaised", \.bgRaised)]
        // Body text and labels on the three surfaces; meta text (timestamps, counts) too.
        for (textName, textRole) in [("textPrimary", \ThemeColors.textPrimary), ("textSecondary", \.textSecondary), ("textTertiary", \.textTertiary)] {
            for (surfaceName, surface) in surfaces {
                pairs.append(Pair(name: "\(textName) on \(surfaceName)", text: textRole, fill: surface, base: surface, minimum: text))
            }
        }
        // A selected row's title (sidebar, on bgBase).
        pairs.append(Pair(name: "textPrimary on bgSelected", text: \.textPrimary, fill: \.bgSelected, base: \.bgBase, minimum: text))
        // State words on their tints (pills, banners), over the window and over a card.
        let states: [(String, Role, Role)] = [
            ("lanternText on lanternTint", \.lanternText, \.lanternTint),
            ("running on runningTint", \.running, \.runningTint),
            ("done on doneTint", \.done, \.doneTint),
            ("failed on failedTint", \.failed, \.failedTint),
        ]
        for (name, textRole, tint) in states {
            pairs.append(Pair(name: "\(name) over bgWindow", text: textRole, fill: tint, base: \.bgWindow, minimum: text))
            pairs.append(Pair(name: "\(name) over bgRaised", text: textRole, fill: tint, base: \.bgRaised, minimum: text))
        }
        // The primary button's label.
        pairs.append(Pair(name: "textOnLantern on lantern", text: \.textOnLantern, fill: \.lantern, base: \.bgWindow, minimum: text))
        // State dots, glyphs, spinners, and bars on the window.
        for (name, role) in [("lantern", \ThemeColors.lantern), ("running", \.running), ("done", \.done), ("failed", \.failed)] {
            pairs.append(Pair(name: "\(name) mark on bgWindow", text: role, fill: \.bgWindow, base: \.bgWindow, minimum: mark))
        }
        return pairs
    }

    /// Pairs the board uses that fall short, with their measured ratios (the report).
    static let exceptions: [String: Double] = [
        // Meta text ("Meta, timestamps") is deliberately faint in both appearances.
        "night-watch-dark: textTertiary on bgBase": 3.35,
        "night-watch-dark: textTertiary on bgWindow": 3.29,
        "night-watch-dark: textTertiary on bgRaised": 3.06,
        "night-watch-light: textTertiary on bgBase": 2.40,
        "night-watch-light: textTertiary on bgWindow": 2.60,
        "night-watch-light: textTertiary on bgRaised": 2.69,
        // Light state pills: the state color on its own tint.
        "night-watch-light: running on runningTint over bgWindow": 3.98,
        "night-watch-light: running on runningTint over bgRaised": 4.11,
        "night-watch-light: done on doneTint over bgWindow": 3.01,
        "night-watch-light: done on doneTint over bgRaised": 3.11,
        "night-watch-light: failed on failedTint over bgWindow": 3.71,
        "night-watch-light: failed on failedTint over bgRaised": 3.84,
        // Light lantern as a dot or glyph on the window.
        "night-watch-light: lantern mark on bgWindow": 2.27,
    ]

    @Test(arguments: Variant.all)
    func everyPairMeetsItsMinimumOrIsADocumentedException(_ variant: Variant) {
        for pair in Self.pairs {
            let ratio = variant.contrast(pair.text, on: pair.fill, over: pair.base)
            let key = "\(variant.testDescription): \(pair.name)"
            if let measured = Self.exceptions[key] {
                #expect(abs(ratio - measured) < 0.01, "\(key) is now \(ratio); update the exception")
                #expect(ratio < pair.minimum, "\(key) now passes (\(ratio)); remove the exception")
            } else {
                #expect(ratio >= pair.minimum, "\(key) is \(ratio), below \(pair.minimum)")
            }
        }
    }

    @Test func everyExceptionNamesARealPair() {
        let keys = Set(Variant.all.flatMap { variant in Self.pairs.map { "\(variant.testDescription): \($0.name)" } })
        #expect(Set(Self.exceptions.keys).subtracting(keys).isEmpty)
    }

    /// The dangerFill button and the failed count badge put white on `failed`, as the board
    /// draws them; neither variant reaches 4.5:1 (dark 3.18, light 4.33).
    @Test(arguments: [(false, 4.33), (true, 3.18)])
    func whiteOnFailedIsADocumentedException(isDark: Bool, measured: Double) {
        let variant = Variant(theme: .nightWatch, isDark: isDark)
        let ratio = HexColor("#ffffff")!.contrast(with: variant.color(\.failed))
        #expect(abs(ratio - measured) < 0.01)
        #expect(ratio < Self.text)
    }

    /// Surfaces stay distinct and ordered: the window is not the chrome, a card is not the
    /// window, and the strong line reads stronger than the subtle one.
    @Test(arguments: Variant.all)
    func surfacesAndLinesStayDistinct(_ variant: Variant) {
        let c = variant.colors
        #expect(Set([c.bgBase, c.bgWindow, c.bgRaised, c.bgSunken, c.bgBubble]).count == 5)
        #expect(variant.contrast(\.lineStrong, on: \.bgWindow) > variant.contrast(\.lineSubtle, on: \.bgWindow))
        #expect(variant.contrast(\.bgSelected, on: \.bgBase, over: \.bgBase) > variant.contrast(\.bgHover, on: \.bgBase, over: \.bgBase))
    }

    /// The state colors must not collapse into each other.
    @Test(arguments: Variant.all)
    func stateColorsAreDistinguishable(_ variant: Variant) {
        let states = [\ThemeColors.lantern, \.running, \.done, \.failed].map(variant.color)
        for i in states.indices {
            for j in states.indices where j > i {
                let (a, b) = (states[i], states[j])
                let distance = ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green)
                    + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
                #expect(distance > 0.12, "\(variant.testDescription): state \(i) vs \(j)")
            }
        }
    }
}

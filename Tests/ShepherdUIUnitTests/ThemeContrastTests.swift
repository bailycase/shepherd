import Testing
@testable import ShepherdUI

/// WCAG contrast for every built-in variant: 4.5:1 for text, 3:1 for dots, glyphs, and bars.
///
/// Shepherd Design's colors are the design's. Where a pair the board uses as text (or a state mark)
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
        // The primary button's label, and a lantern badge's.
        pairs.append(Pair(name: "textOnPrimary on primary", text: \.textOnPrimary, fill: \.primary, base: \.bgWindow, minimum: text))
        pairs.append(Pair(name: "textOnLantern on lantern", text: \.textOnLantern, fill: \.lantern, base: \.bgWindow, minimum: text))
        // The Browser's element tag and the design canvas's selection tag.
        pairs.append(Pair(name: "textOnRunning on running", text: \.textOnRunning, fill: \.running, base: \.bgWindow, minimum: text))
        // State dots, glyphs, and bars on the window.
        for (name, role) in [("lantern", \ThemeColors.lantern), ("running", \.running), ("done", \.done), ("failed", \.failed)] {
            pairs.append(Pair(name: "\(name) mark on bgWindow", text: role, fill: \.bgWindow, base: \.bgWindow, minimum: mark))
        }
        return pairs
    }

    /// Pairs the board uses that fall short, with their measured ratios (the report).
    static let exceptions: [String: Double] = [
        // Meta text ("Meta, timestamps") is deliberately faint in both appearances.
        "shepherd-design-dark: textTertiary on bgBase": 3.36,
        "shepherd-design-dark: textTertiary on bgWindow": 3.36,
        "shepherd-design-dark: textTertiary on bgRaised": 2.98,
        "shepherd-design-light: textTertiary on bgBase": 2.40,
        "shepherd-design-light: textTertiary on bgWindow": 2.40,
        "shepherd-design-light: textTertiary on bgRaised": 2.57,
        // State pills: the state color on its own tint.
        "shepherd-design-light: running on runningTint over bgWindow": 3.86,
        "shepherd-design-light: running on runningTint over bgRaised": 4.11,
        "shepherd-design-light: done on doneTint over bgWindow": 3.48,
        "shepherd-design-light: done on doneTint over bgRaised": 3.71,
        "shepherd-design-light: failed on failedTint over bgWindow": 3.91,
        "shepherd-design-light: failed on failedTint over bgRaised": 4.17,
        "shepherd-design-dark: failed on failedTint over bgRaised": 4.4998,
        // The Browser's element tag and the design canvas's selection tag put white on `running`
        // in mono 10.5, as the board draws it; dark falls short, the board's choice.
        "shepherd-design-dark: textOnRunning on running": 2.39,
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

    /// The dangerFill button and the failed count badge put white on `failed`: light reaches
    /// 4.5:1 (4.77); dark's lighter red falls short (2.82).
    @Test(arguments: [(false, 4.77), (true, 2.82)])
    func whiteOnFailedIsADocumentedExceptionInDark(isDark: Bool, measured: Double) {
        let variant = Variant(theme: .shepherdDesign, isDark: isDark)
        let ratio = HexColor("#ffffff")!.contrast(with: variant.color(\.failed))
        #expect(abs(ratio - measured) < 0.01)
        #expect((ratio >= Self.text) == !isDark)
    }

    /// `textOnRunning` on `running`, as the Browser's element tag and the design canvas's
    /// selection tag draw it in mono 10.5: light reaches 4.5:1; dark falls short (2.39), the
    /// board's choice (also covered as a `pairs` exception above).
    @Test(arguments: [(false, 4.70), (true, 2.39)])
    func textOnRunningIsADocumentedExceptionInDark(isDark: Bool, measured: Double) {
        let variant = Variant(theme: .shepherdDesign, isDark: isDark)
        let ratio = variant.color(\.textOnRunning).contrast(with: variant.color(\.running))
        #expect(abs(ratio - measured) < 0.01, "textOnRunning on running is now \(ratio)")
        #expect((ratio >= Self.text) == !isDark)
    }

    /// The primary fill keeps its label at 4.5:1 in both variants.
    @Test(arguments: [false, true])
    func primaryFillKeepsTheLabelReadable(isDark: Bool) {
        let variant = Variant(theme: .shepherdDesign, isDark: isDark)
        #expect(variant.color(\.textOnPrimary).contrast(with: variant.color(\.primary)) >= Self.text)
    }

    /// White on the dangerFill button's pressed fill: light reaches 4.5:1 (5.42); dark is darker
    /// than `failed` but still short (4.23), as the board draws it.
    @Test(arguments: [(false, 5.42), (true, 4.23)])
    func whiteOnPressedDangerFill(isDark: Bool, measured: Double) throws {
        let fill = try #require(HexColor(isDark ? SHButtonFills.failedPressed.dark : SHButtonFills.failedPressed.light))
        let ratio = HexColor("#ffffff")!.contrast(with: fill)
        #expect(abs(ratio - measured) < 0.01)
        #expect((ratio >= Self.text) == !isDark)
    }

    /// Surfaces stay distinct: a card, a well, and a bubble are not the window (the boards draw
    /// the chrome and the window in one fill), and the strong line reads stronger than the subtle one.
    @Test(arguments: Variant.all)
    func surfacesAndLinesStayDistinct(_ variant: Variant) {
        let c = variant.colors
        #expect(Set([c.bgWindow, c.bgRaised, c.bgSunken, c.bgBubble]).count == 4)
        #expect(variant.contrast(\.lineStrong, on: \.bgWindow, over: \.bgWindow) > variant.contrast(\.lineSubtle, on: \.bgWindow, over: \.bgWindow))
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

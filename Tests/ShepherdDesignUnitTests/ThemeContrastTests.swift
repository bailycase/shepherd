import Testing
@testable import ShepherdDesign

/// The accessibility rules from the design handoff (§7), for every built-in variant.
@Suite("Theme contrast (WCAG)")
struct ThemeContrastTests {
    typealias Role = KeyPath<ThemeColors, String>

    static var textRoles: [(String, Role)] { [
        ("text", \.text), ("textSecondary", \.textSecondary), ("textTertiary", \.textTertiary), ("textMuted", \.textMuted),
    ] }
    static var surfaces: [(String, Role)] { [("bgSurface", \.bgSurface), ("bgCanvas", \.bgCanvas), ("bgRaised", \.bgRaised)] }
    static var semantics: [(String, text: Role, fill: Role, base: Role)] { [
        ("accent", \.accentText, \.accentBg, \.accent),
        ("success", \.successText, \.successBg, \.success),
        ("warning", \.warningText, \.warningBg, \.warning),
        ("danger", \.dangerText, \.dangerBg, \.danger),
    ] }

    @Test(arguments: Variant.all)
    func everyTextRoleMeetsAAOnEverySurface(_ variant: Variant) {
        for (textName, text) in Self.textRoles {
            for (surfaceName, surface) in Self.surfaces {
                let ratio = variant.contrast(text, on: surface)
                #expect(ratio >= 4.5, "\(variant.testDescription): \(textName) on \(surfaceName) is \(ratio)")
            }
        }
    }

    @Test(arguments: Variant.all)
    func semanticTextMeetsAAOnItsOwnFillAndOnTheSurface(_ variant: Variant) {
        for (name, text, fill, _) in Self.semantics {
            #expect(variant.contrast(text, on: fill) >= 4.5, "\(variant.testDescription): \(name)Text on \(name)Bg")
            #expect(variant.contrast(text, on: \.bgSurface) >= 4.5, "\(variant.testDescription): \(name)Text on bgSurface")
        }
    }

    /// Selected sidebar rows carry labels and counts; primary buttons invert text and surface;
    /// the stopped pill puts secondary text on the bubble fill.
    @Test(arguments: Variant.all)
    func selectedRowsPrimaryButtonsAndPillsAreReadable(_ variant: Variant) {
        #expect(variant.contrast(\.text, on: \.bgSelected) >= 4.5)
        #expect(variant.contrast(\.textMuted, on: \.bgSelected) >= 4.0)
        #expect(variant.contrast(\.bgSurface, on: \.text) >= 4.5)
        #expect(variant.contrast(\.textSecondary, on: \.bgBubble) >= 4.5)
    }

    /// Glyphs, dots, and bars need 3:1 against the surface (WCAG non-text contrast).
    @Test(arguments: Variant.all)
    func semanticGlyphColorsAreVisibleOnTheSurface(_ variant: Variant) {
        for (name, _, _, base) in Self.semantics {
            #expect(variant.contrast(base, on: \.bgSurface) >= 3, "\(variant.testDescription): \(name)")
        }
    }

    @Test(arguments: Variant.all)
    func semanticColorsAreDistinguishableFromEachOther(_ variant: Variant) {
        let bases = Self.semantics.map { HexColor(variant.colors[keyPath: $0.base])! }
        for i in bases.indices {
            for j in bases.indices where j > i {
                let (a, b) = (bases[i], bases[j])
                let distance = ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green)
                    + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
                #expect(distance > 0.12, "\(variant.testDescription): \(Self.semantics[i].0) vs \(Self.semantics[j].0)")
            }
        }
    }

    /// Surfaces keep their order: canvas, surface, and raised differ; borders step up in
    /// strength; selection reads stronger than hover on the canvas.
    @Test(arguments: Variant.all)
    func surfaceAndBorderLayersStayDistinct(_ variant: Variant) {
        let c = variant.colors
        #expect(c.bgCanvas != c.bgSurface && c.bgSurface != c.bgRaised)
        #expect(variant.contrast(\.border, on: \.bgSurface) > variant.contrast(\.borderSubtle, on: \.bgSurface))
        #expect(variant.contrast(\.borderStrong, on: \.bgSurface) > variant.contrast(\.border, on: \.bgSurface))
        #expect(variant.contrast(\.bgSelected, on: \.bgCanvas) > variant.contrast(\.bgHoverStrong, on: \.bgCanvas))
    }

    /// Disabled text is deliberately below the text ramp.
    @Test(arguments: Variant.all)
    func disabledTextIsTheFaintestText(_ variant: Variant) {
        #expect(variant.contrast(\.textDisabled, on: \.bgSurface) < variant.contrast(\.textMuted, on: \.bgSurface))
    }
}

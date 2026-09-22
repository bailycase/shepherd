import Foundation
import Testing
@testable import ShepherdDesign

@Suite("Theme definitions")
struct ThemeDefinitionTests {
    static let builtIns: [ThemeDefinition] = [.basalt]

    @Test(arguments: builtIns)
    func everyColorParses(theme: ThemeDefinition) {
        #expect(theme.invalidColors.isEmpty, "\(theme.id): \(theme.invalidColors)")
        #expect(theme.light.terminal.palette.count == 16 && theme.dark.terminal.palette.count == 16)
    }

    /// Themes are data: the JSON a user theme would be written in round-trips exactly.
    @Test(arguments: builtIns)
    func codableRoundTrip(theme: ThemeDefinition) throws {
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(ThemeDefinition.self, from: data) == theme)
    }

    @Test func malformedColorsAreReported() {
        var theme = ThemeDefinition.basalt
        theme.dark.colors.accent = "#12345"
        theme.light.terminal.palette[3] = "blue"
        #expect(theme.invalidColors == ["light.terminal.palette[3]", "dark.colors.accent"])
    }

    /// Shells render on the thread surface, so a terminal's background is the theme's surface.
    @Test(arguments: builtIns)
    func terminalBackgroundIsTheSurface(theme: ThemeDefinition) {
        for variant in [theme.light, theme.dark] {
            #expect(HexColor(variant.terminal.background) == HexColor(variant.colors.bgSurface))
        }
    }
}

/// The accessibility rules from the design handoff (§7), checked for every built-in variant.
@Suite("Theme contrast")
struct ThemeContrastTests {
    static let variants: [(String, ThemeVariant)] = ThemeDefinitionTests.builtIns.flatMap {
        [("\($0.id)-light", $0.light), ("\($0.id)-dark", $0.dark)]
    }

    private func ratio(_ a: String, _ b: String) -> Double {
        HexColor(a)!.contrast(with: HexColor(b)!)
    }

    @Test func mutedTextIsReadableOnEverySurfaceItSitsOn() {
        for (name, variant) in Self.variants {
            let c = variant.colors
            for (label, background) in [("bgSurface", c.bgSurface), ("bgCanvas", c.bgCanvas), ("bgRaised", c.bgRaised)] {
                for (role, text) in [("text", c.text), ("textSecondary", c.textSecondary), ("textTertiary", c.textTertiary), ("textMuted", c.textMuted)] {
                    #expect(ratio(text, background) >= 4.5, "\(name): \(role) on \(label) is \(ratio(text, background))")
                }
            }
            // Selected sidebar rows carry labels and counts.
            #expect(ratio(c.text, c.bgSelected) >= 4.5, "\(name): text on bgSelected")
            #expect(ratio(c.textMuted, c.bgSelected) >= 4.0, "\(name): textMuted on bgSelected")
            // Primary buttons are text-on-surface inverted.
            #expect(ratio(c.bgSurface, c.text) >= 4.5, "\(name): primary label")
        }
    }

    @Test func semanticTextIsReadableOnItsOwnFillAndOnTheSurface() {
        for (name, variant) in Self.variants {
            let c = variant.colors
            let pairs = [("accent", c.accentText, c.accentBg), ("success", c.successText, c.successBg),
                         ("warning", c.warningText, c.warningBg), ("danger", c.dangerText, c.dangerBg)]
            for (role, text, fill) in pairs {
                #expect(ratio(text, fill) >= 4.5, "\(name): \(role)Text on \(role)Bg is \(ratio(text, fill))")
                #expect(ratio(text, c.bgSurface) >= 4.5, "\(name): \(role)Text on bgSurface")
            }
        }
    }

    /// Glyphs, dots, and bars need 3:1 against the surface; the four semantic colors must also
    /// stay distinguishable from one another.
    @Test func semanticColorsAreVisibleAndDistinct() {
        for (name, variant) in Self.variants {
            let c = variant.colors
            let bases = [c.accent, c.success, c.warning, c.danger]
            for base in bases { #expect(ratio(base, c.bgSurface) >= 3, "\(name): \(base) on surface") }
            for i in bases.indices {
                for j in bases.indices where j > i {
                    let a = HexColor(bases[i])!, b = HexColor(bases[j])!
                    let distance = ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
                    #expect(distance > 0.12, "\(name): \(bases[i]) and \(bases[j]) are too close")
                }
            }
        }
    }

    /// Surfaces keep their order: canvas and surface differ, hover sits between surface and
    /// selection, and borders are visible on the surface.
    @Test func surfaceLayersStayDistinct() {
        for (name, variant) in Self.variants {
            let c = variant.colors
            #expect(c.bgCanvas != c.bgSurface && c.bgSurface != c.bgRaised, Comment(rawValue: name))
            #expect(ratio(c.border, c.bgSurface) > ratio(c.borderSubtle, c.bgSurface), Comment(rawValue: name))
            #expect(ratio(c.borderStrong, c.bgSurface) > ratio(c.border, c.bgSurface), Comment(rawValue: name))
            #expect(ratio(c.bgSelected, c.bgCanvas) > ratio(c.bgHoverStrong, c.bgCanvas), Comment(rawValue: name))
        }
    }
}

extension ThemeDefinition: @retroactive CustomTestStringConvertible {
    public var testDescription: String { id }
}

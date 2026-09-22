import Foundation
import Testing
@testable import ShepherdDesign

@Suite("Built-in themes")
struct ThemeDefinitionTests {
    @Test(arguments: Variant.themes)
    func everyColorInEveryVariantParses(_ theme: ThemeDefinition) {
        #expect(theme.invalidColors.isEmpty, "\(theme.invalidColors)")
    }

    @Test(arguments: Variant.all)
    func everyRoleIsASixDigitHexColor(_ variant: Variant) {
        for group in [variant.colors, variant.value.syntax, variant.value.pi] as [Any] {
            for child in Mirror(reflecting: group).children {
                let value = child.value as? String
                #expect(value.flatMap(HexColor.init) != nil, "\(variant.testDescription).\(child.label ?? "?") = \(value ?? "nil")")
            }
        }
    }

    @Test(arguments: Variant.all)
    func terminalHasTheSixteenANSIColors(_ variant: Variant) {
        #expect(variant.value.terminal.palette.count == 16)
    }

    /// Shells render on the thread surface.
    @Test(arguments: Variant.all)
    func terminalBackgroundIsTheSurface(_ variant: Variant) {
        #expect(HexColor(variant.value.terminal.background) == HexColor(variant.colors.bgSurface))
    }

    @Test(arguments: Variant.themes)
    func lightAndDarkVariantsDiffer(_ theme: ThemeDefinition) {
        #expect(theme.variant(dark: false) == theme.light)
        #expect(theme.variant(dark: true) == theme.dark)
        #expect(theme.light != theme.dark)
    }

    /// Themes are data: the JSON a user theme would be written in round-trips exactly.
    @Test(arguments: Variant.themes)
    func codableRoundTrip(_ theme: ThemeDefinition) throws {
        #expect(try JSONDecoder().decode(ThemeDefinition.self, from: JSONEncoder().encode(theme)) == theme)
    }

    @Test func aThemeMissingARoleFailsToDecode() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ThemeDefinition.basalt)) as? [String: Any])
        var dark = try #require(object["dark"] as? [String: Any])
        var colors = try #require(dark["colors"] as? [String: Any])
        colors.removeValue(forKey: "dangerBg")
        dark["colors"] = colors
        object["dark"] = dark
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ThemeDefinition.self, from: data) }
    }

    @Test func malformedColorsAreReportedWithTheirPaths() {
        var theme = ThemeDefinition.basalt
        theme.dark.colors.accent = "#12345"
        theme.light.terminal.palette[3] = "blue"
        theme.light.terminal.selectionBackground = "nope"
        theme.dark.syntax.keyword = ""
        #expect(theme.invalidColors == [
            "light.terminal.selectionBackground", "light.terminal.palette[3]",
            "dark.colors.accent", "dark.syntax.keyword",
        ])
    }

    @Test func absentOptionalTerminalColorsAreValid() {
        var theme = ThemeDefinition.basalt
        theme.light.terminal.selectionBackground = nil
        theme.light.terminal.selectionForeground = nil
        #expect(theme.invalidColors.isEmpty)
    }
}

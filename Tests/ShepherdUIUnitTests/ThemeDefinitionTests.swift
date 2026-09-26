import Foundation
import Testing
@testable import ShepherdUI

@Suite("Built-in themes")
struct ThemeDefinitionTests {
    /// The Foundations board's roles, by their Swift names. A rename or a dropped role fails here.
    static let boardRoles = [
        "bgBase", "bgWindow", "bgRaised", "bgSunken", "bgBubble", "bgHover", "bgSelected",
        "lineSubtle", "lineStrong", "textPrimary", "textSecondary", "textTertiary", "textOnLantern",
        "lantern", "lanternText", "lanternTint", "running", "runningTint", "done", "doneTint", "failed", "failedTint",
    ]

    @Test(arguments: Variant.themes)
    func everyColorInEveryVariantParses(_ theme: ThemeDefinition) {
        #expect(theme.invalidColors.isEmpty, "\(theme.invalidColors)")
    }

    @Test(arguments: Variant.all)
    func everyBoardRoleIsPresent(_ variant: Variant) {
        let roles = Mirror(reflecting: variant.colors).children.compactMap(\.label)
        #expect(roles == Self.boardRoles)
        for child in Mirror(reflecting: variant.colors).children {
            #expect((child.value as? String).flatMap(HexColor.init) != nil, "\(variant.testDescription).\(child.label ?? "?")")
        }
    }

    /// Hover, selection, and the state tints are translucent; everything else is solid.
    @Test(arguments: Variant.all)
    func onlyHoverSelectionAndTintsAreTranslucent(_ variant: Variant) {
        let translucent = Mirror(reflecting: variant.colors).children.compactMap { child -> String? in
            guard let label = child.label, let value = child.value as? String, let color = HexColor(value) else { return nil }
            return color.isOpaque ? nil : label
        }
        #expect(translucent == ["bgHover", "bgSelected", "lanternTint", "runningTint", "doneTint", "failedTint"])
    }

    @Test(arguments: Variant.all)
    func syntaxAndTerminalColorsAreOpaqueHex(_ variant: Variant) {
        for group in [variant.value.syntax] as [Any] {
            for child in Mirror(reflecting: group).children {
                let value = child.value as? String
                #expect(value.flatMap(HexColor.init)?.isOpaque == true, "\(variant.testDescription).\(child.label ?? "?") = \(value ?? "nil")")
            }
        }
        #expect(variant.value.terminal.palette.allSatisfy { HexColor($0)?.isOpaque == true })
    }

    @Test(arguments: Variant.all)
    func terminalHasTheSixteenANSIColors(_ variant: Variant) {
        #expect(variant.value.terminal.palette.count == 16)
    }

    /// Terminal panes sit on the thread's window surface and write in its text color, with a
    /// block cursor in that color too (TerminalSplit).
    @Test(arguments: Variant.all)
    func terminalFollowsTheWindowSurface(_ variant: Variant) {
        let terminal = variant.value.terminal
        #expect(HexColor(terminal.background) == HexColor(variant.colors.bgWindow))
        #expect(HexColor(terminal.foreground) == HexColor(variant.colors.textPrimary))
        #expect(HexColor(terminal.cursor) == HexColor(variant.colors.textPrimary))
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
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ThemeDefinition.nightWatch)) as? [String: Any])
        var dark = try #require(object["dark"] as? [String: Any])
        var colors = try #require(dark["colors"] as? [String: Any])
        colors.removeValue(forKey: "failedTint")
        dark["colors"] = colors
        object["dark"] = dark
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ThemeDefinition.self, from: data) }
    }

    @Test func malformedColorsAreReportedWithTheirPaths() {
        var theme = ThemeDefinition.nightWatch
        theme.dark.colors.running = "#12345"
        theme.light.terminal.palette[3] = "blue"
        theme.light.terminal.selectionBackground = "nope"
        theme.dark.syntax.keyword = ""
        // Alpha is for UI roles only: renderers get opaque colors.
        theme.dark.terminal.cursor = "#f2a93b80"
        #expect(theme.invalidColors == [
            "light.terminal.selectionBackground", "light.terminal.palette[3]",
            "dark.colors.running", "dark.syntax.keyword", "dark.terminal.cursor",
        ])
    }

    @Test func absentOptionalTerminalColorsAreValid() {
        var theme = ThemeDefinition.nightWatch
        theme.light.terminal.selectionBackground = nil
        theme.light.terminal.selectionForeground = nil
        #expect(theme.invalidColors.isEmpty)
    }
}

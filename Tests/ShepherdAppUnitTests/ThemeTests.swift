import Foundation
import SwiftUI
import Testing
@testable import ShepherdApp

/// The theme file pi watches (for a pi run by hand in a shell pane) and the variant marker
/// Neovim watches are external contracts.
@Suite("Pi theme file")
struct PiThemeFileTests {
    /// pi's theme schema: every key is required.
    private static let requiredColorKeys: Set<String> = [
        "accent", "border", "borderAccent", "borderMuted", "success", "error", "warning",
        "muted", "dim", "text", "thinkingText",
        "selectedBg", "scrollbarThumb", "searchMatchBg", "searchMatchText",
        "userMessageBg", "userMessageText", "customMessageBg", "customMessageText",
        "customMessageLabel", "toolPendingBg", "toolSuccessBg", "toolErrorBg", "toolTitle", "toolOutput",
        "mdHeading", "mdLink", "mdLinkUrl", "mdCode", "mdCodeBlock", "mdCodeBlockBorder",
        "mdQuote", "mdQuoteBorder", "mdHr", "mdListBullet",
        "toolDiffAdded", "toolDiffRemoved", "toolDiffContext",
        "syntaxComment", "syntaxKeyword", "syntaxFunction", "syntaxVariable", "syntaxString",
        "syntaxNumber", "syntaxType", "syntaxOperator", "syntaxPunctuation",
        "thinkingOff", "thinkingMinimal", "thinkingLow", "thinkingMedium", "thinkingHigh",
        "thinkingXhigh", "thinkingMax", "bashMode",
    ]

    @Test(arguments: ShepherdTheme.all.map(\.id))
    func everyVariantWritesACompletePiTheme(id: String) throws {
        let theme = try #require(ShepherdTheme.all.first { $0.id == id })
        let data = try ShepherdPiTheme.encodedData(for: theme)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(document["name"] as? String == "night-watch")
        #expect((document["$schema"] as? String)?.hasSuffix("theme-schema.json") == true)
        let colors = try #require(document["colors"] as? [String: String])
        #expect(Set(colors.keys) == Self.requiredColorKeys)
        for (key, value) in colors {
            // Empty inherits Ghostty's foreground; everything else is #RRGGBB.
            #expect(value.isEmpty || value.wholeMatch(of: /#[0-9A-Fa-f]{6}/) != nil, "\(key) = \(value)")
        }
        #expect(data.last == 0x0A)
    }

    @Test func variantIDsAreTheSpellingNeovimWatches() {
        #expect(ShepherdTheme.all.map(\.id) == ["night-watch-dark", "night-watch-light"])
        #expect(ShepherdTheme.nightWatchDark.isDark && !ShepherdTheme.nightWatchLight.isDark)
    }

    @Test func installingWritesTheThemeAndTheActiveVariantMarker() throws {
        let directory = try Fixture.scratchDirectory("pi-theme")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(ShepherdPiTheme.variantFilename)

        let path = try ShepherdPiTheme.installedPath(for: .nightWatchDark, directory: directory)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == ShepherdPiTheme.encodedData(for: .nightWatchDark))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "night-watch-dark\n")

        #expect(try ShepherdPiTheme.installedPath(for: .nightWatchLight, directory: directory) == path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == ShepherdPiTheme.encodedData(for: .nightWatchLight))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "night-watch-light\n")
    }

    /// pi watches the file; rewriting identical bytes would trigger a pointless reload.
    @Test func reinstallingTheSameThemeLeavesTheFileAlone() throws {
        let directory = try Fixture.scratchDirectory("pi-theme")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try ShepherdPiTheme.installedPath(for: .nightWatchDark, directory: directory)
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)

        _ = try ShepherdPiTheme.installedPath(for: .nightWatchDark, directory: directory)

        let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(modified == past)
    }
}

@Suite("Appearance mode")
@MainActor
struct AppearanceModeTests {
    private func manager(_ defaults: UserDefaults, env: String? = nil, system: ColorScheme) -> ThemeManager {
        ThemeManager(store: defaults, environmentTheme: env, systemColorScheme: system)
    }

    @Test(arguments: [(ColorScheme.dark, "night-watch-dark"), (.light, "night-watch-light")])
    func systemModeFollowsTheSystemAppearance(system: ColorScheme, theme: String) {
        let themes = manager(Fixture.defaults(), system: system)
        #expect(themes.mode == .system)
        #expect(themes.current.id == theme)
    }

    @Test func aChosenModePersistsAndOverridesTheSystem() {
        let defaults = Fixture.defaults()
        manager(defaults, system: .dark).select(.light)

        let reloaded = manager(defaults, system: .dark)
        #expect(reloaded.mode == .light)
        #expect(reloaded.current.id == "night-watch-light")
        #expect(defaults.string(forKey: "shepherd.appearance") == "light")
    }

    @Test func systemAppearanceChangesOnlyMatterInSystemMode() {
        let system = manager(Fixture.defaults(), system: .dark)
        #expect(system.updateSystemColorScheme(.light)?.id == "night-watch-light")
        #expect(system.updateSystemColorScheme(.light) == nil, "no change, no reconfiguration")

        let pinned = manager(Fixture.defaults(), system: .dark)
        pinned.select(.dark)
        #expect(pinned.updateSystemColorScheme(.light) == nil)
        #expect(pinned.current.id == "night-watch-dark")
    }

    @Test func resetReturnsToSystemAndClearsTheStoredChoice() {
        let defaults = Fixture.defaults()
        let themes = manager(defaults, system: .dark)
        themes.select(.light)

        #expect(themes.resetToDefault().id == "night-watch-dark")
        #expect(themes.mode == .system)
        #expect(defaults.object(forKey: "shepherd.appearance") == nil)
    }

    /// `SHEPHERD_THEME` forces a variant at launch (screenshots) and is what reset returns to.
    @Test(arguments: [("night-watch-dark", AppearanceMode.dark), ("shepherd-dark", .dark), ("night-watch-light", .light)])
    func theLaunchOverrideWinsOverStoredAndSystemChoices(env: String, mode: AppearanceMode) {
        let defaults = Fixture.defaults()
        defaults.set("system", forKey: "shepherd.appearance")
        let themes = manager(defaults, env: env, system: mode == .dark ? .light : .dark)
        #expect(themes.mode == mode)
        #expect(themes.resetToDefault().id == (mode == .dark ? "night-watch-dark" : "night-watch-light"))
    }

    @Test func anUnknownLaunchOverrideIsIgnored() {
        #expect(manager(Fixture.defaults(), env: "solarized", system: .light).mode == .system)
    }
}

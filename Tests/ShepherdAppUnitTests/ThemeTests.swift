import Foundation
import SwiftUI
import Testing
@testable import ShepherdApp

/// The variant marker Neovim watches is independent of pi's terminal theme.
@Suite("Theme marker")
struct ThemeMarkerTests {

    @Test func variantIDsAreTheSpellingNeovimWatches() {
        #expect(ShepherdTheme.all.map(\.id) == ["shepherd-design-dark", "shepherd-design-light"])
        #expect(ShepherdTheme.shepherdDesignDark.isDark && !ShepherdTheme.shepherdDesignLight.isDark)
    }

    @Test func installingWritesOnlyTheActiveVariantMarker() throws {
        let directory = try Fixture.scratchDirectory("pi-theme")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(ShepherdThemeMarker.filename)

        try ShepherdThemeMarker.install(for: .shepherdDesignDark, directory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [ShepherdThemeMarker.filename])
        #expect(try String(contentsOf: marker, encoding: .utf8) == "shepherd-design-dark\n")

        try ShepherdThemeMarker.install(for: .shepherdDesignLight, directory: directory)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "shepherd-design-light\n")
    }

    /// Rewriting identical bytes would trigger a pointless editor reload.
    @Test func reinstallingTheSameThemeLeavesTheMarkerAlone() throws {
        let directory = try Fixture.scratchDirectory("pi-theme")
        defer { try? FileManager.default.removeItem(at: directory) }
        try ShepherdThemeMarker.install(for: .shepherdDesignDark, directory: directory)
        let path = directory.appendingPathComponent(ShepherdThemeMarker.filename).path
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)

        try ShepherdThemeMarker.install(for: .shepherdDesignDark, directory: directory)

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

    @Test(arguments: [(ColorScheme.dark, "shepherd-design-dark"), (.light, "shepherd-design-light")])
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
        #expect(reloaded.current.id == "shepherd-design-light")
        #expect(defaults.string(forKey: "shepherd.appearance") == "light")
    }

    @Test func systemAppearanceChangesOnlyMatterInSystemMode() {
        let system = manager(Fixture.defaults(), system: .dark)
        #expect(system.updateSystemColorScheme(.light)?.id == "shepherd-design-light")
        #expect(system.updateSystemColorScheme(.light) == nil, "no change, no reconfiguration")

        let pinned = manager(Fixture.defaults(), system: .dark)
        pinned.select(.dark)
        #expect(pinned.updateSystemColorScheme(.light) == nil)
        #expect(pinned.current.id == "shepherd-design-dark")
    }

    @Test func resetReturnsToSystemAndClearsTheStoredChoice() {
        let defaults = Fixture.defaults()
        let themes = manager(defaults, system: .dark)
        themes.select(.light)

        #expect(themes.resetToDefault().id == "shepherd-design-dark")
        #expect(themes.mode == .system)
        #expect(defaults.object(forKey: "shepherd.appearance") == nil)
    }

    /// `SHEPHERD_THEME` forces a variant at launch (screenshots) and is what reset returns to.
    @Test(arguments: [("shepherd-design-dark", AppearanceMode.dark), ("shepherd-dark", .dark), ("shepherd-design-light", .light)])
    func theLaunchOverrideWinsOverStoredAndSystemChoices(env: String, mode: AppearanceMode) {
        let defaults = Fixture.defaults()
        defaults.set("system", forKey: "shepherd.appearance")
        let themes = manager(defaults, env: env, system: mode == .dark ? .light : .dark)
        #expect(themes.mode == mode)
        #expect(themes.resetToDefault().id == (mode == .dark ? "shepherd-design-dark" : "shepherd-design-light"))
    }

    @Test func anUnknownLaunchOverrideIsIgnored() {
        #expect(manager(Fixture.defaults(), env: "solarized", system: .light).mode == .system)
    }
}

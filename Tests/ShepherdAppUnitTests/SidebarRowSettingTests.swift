import Foundation
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Settings ▸ Appearance ▸ Sidebar rows: Night Watch's Standard by default, and remembered.
@Suite("Sidebar rows setting")
@MainActor
struct SidebarRowSettingTests {
    @Test func sidebarRowsDefaultToStandardAndPersist() {
        let store = Fixture.defaults()
        #expect(AppSettings(store: store).sidebarRowDensity == .standard)
        AppSettings(store: store).sidebarRowDensity = .compact
        #expect(AppSettings(store: store).sidebarRowDensity == .compact)
        #expect(store.string(forKey: "shepherd.sidebarRowDensity") == "compact")
    }

    @Test func anUnknownStoredValueFallsBackToStandard() {
        let store = Fixture.defaults()
        store.set("roomy", forKey: AppSettings.Key.sidebarRowDensity)
        #expect(AppSettings(store: store).sidebarRowDensity == .standard)
    }

    @Test func resettingReturnsToStandard() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        settings.sidebarRowDensity = .comfortable
        settings.resetToDefaults()
        #expect(settings.sidebarRowDensity == .standard)
        #expect(store.object(forKey: AppSettings.Key.sidebarRowDensity) == nil)
    }
}

/// Settings ▸ Appearance ▸ Sidebar: Organize by (Activity by default), Group by host (off) and
/// Keep idle threads (7 days), each remembered and reset.
@Suite("Sidebar organize settings")
@MainActor
struct SidebarOrganizeSettingTests {
    @Test func theSidebarIsOrganizedByActivityByDefault() {
        let settings = AppSettings(store: Fixture.defaults())
        #expect(settings.sidebarStyle == .activity)
        #expect(!settings.sidebarGroupByHost)
        #expect(settings.sidebarKeepIdleDays == 7)
    }

    @Test func eachChoicePersists() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        settings.sidebarStyle = .projects
        settings.sidebarGroupByHost = true
        settings.sidebarKeepIdleDays = 0
        let reloaded = AppSettings(store: store)
        #expect(reloaded.sidebarStyle == .projects && reloaded.sidebarGroupByHost && reloaded.sidebarKeepIdleDays == 0)
        #expect(store.string(forKey: AppSettings.Key.sidebarStyle) == "projects")
    }

    /// A hand-edited or stale value falls back to the default rather than an unoffered choice.
    @Test(arguments: [("sideways", 5), ("projects", 7)] as [(String, Int)])
    func unknownStoredValuesFallBack(style: String, days: Int) {
        let store = Fixture.defaults()
        store.set(style, forKey: AppSettings.Key.sidebarStyle)
        store.set(days, forKey: AppSettings.Key.sidebarKeepIdleDays)
        let settings = AppSettings(store: store)
        #expect(settings.sidebarStyle == (style == "projects" ? .projects : .activity))
        #expect(settings.sidebarKeepIdleDays == 7)
    }

    @Test func resettingReturnsToActivity() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        settings.sidebarStyle = .projects
        settings.sidebarGroupByHost = true
        settings.sidebarKeepIdleDays = 30
        settings.resetToDefaults()
        #expect(settings.sidebarStyle == .activity && !settings.sidebarGroupByHost && settings.sidebarKeepIdleDays == 7)
        for key in [AppSettings.Key.sidebarStyle, AppSettings.Key.sidebarGroupByHost, AppSettings.Key.sidebarKeepIdleDays] {
            #expect(store.object(forKey: key) == nil)
        }
    }
}

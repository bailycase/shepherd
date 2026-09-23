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

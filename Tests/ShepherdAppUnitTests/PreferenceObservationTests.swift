import Foundation
import Observation
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

private final class Notified: @unchecked Sendable {
    var fired = false
}

/// Shortcut hints, menus, the sidebar and the window's appearance read these preferences
/// directly, so a change must reach whatever read them with no plumbing in between.
@Suite("Preference observation")
@MainActor
struct PreferenceObservationTests {
    @Test func rebindingAShortcutReachesWhatShowsIt() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        let notified = Notified()
        withObservationTracking { _ = keys.display(.renameAgent) } onChange: { notified.fired = true }
        keys.assign(KeyChord(key: "k", command: true, shift: true), to: .renameAgent)
        #expect(notified.fired)
    }

    /// The recorder's flag gates the navigation fast path only; nothing draws it.
    @Test func recordingAShortcutRedrawsNothing() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        let notified = Notified()
        withObservationTracking { _ = keys.isRecording } onChange: { notified.fired = true }
        keys.isRecording = true
        #expect(!notified.fired)
    }

    @Test func aChangedSettingReachesItsReaders() {
        let settings = AppSettings(store: Fixture.defaults())
        let notified = Notified()
        withObservationTracking { _ = settings.sidebarRowDensity } onChange: { notified.fired = true }
        settings.sidebarRowDensity = .compact
        #expect(notified.fired)
    }

    @Test func choosingAnAppearanceReachesItsReaders() {
        let themes = ThemeManager(store: Fixture.defaults(), environmentTheme: nil, systemColorScheme: .dark)
        let notified = Notified()
        withObservationTracking { _ = themes.mode } onChange: { notified.fired = true }
        themes.select(.light)
        #expect(notified.fired)
    }
}

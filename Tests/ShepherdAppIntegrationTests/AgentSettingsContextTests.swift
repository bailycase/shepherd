import AppKit
import Foundation
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings ▸ Agents ▸ Context, in a real window and pressed the way VoiceOver presses (`ControlPress`,
/// no event posted): each control is found in the accessibility tree and its press action run, and what
/// the press did is read back: the setting, and what reached the pi home. SwiftUI draws the tree only for
/// a process an assistive client is attached to, so each scenario runs in its own process.
@Suite("Agents settings: Context", .integrationTimeLimit)
struct AgentSettingsContextTests {
    @Test func theTrimSwitchTurnsOldToolOutputTrimmingOffAndOn() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.switchingTrimming() }
        }
    }

    @Test func theDeferSwitchTurnsToolDeferralOffAndOnBesideTheTrimSwitch() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.switchingDeferral() }
        }
    }

    @Test func compactAtOffersPisDefaultAndEachShareAndHandsAShareOn() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.choosingACompactionShare(from: nil, choosing: "80%", expecting: 80) }
        }
    }

    @Test func compactAtHandsPisDefaultBackAfterAShare() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.choosingACompactionShare(from: 70, choosing: "Default", expecting: nil) }
        }
    }

    // MARK: Scenarios

    private static let trim = "Trim old tool output from the model's context"
    private static let defers = "Defer rarely used tools"

    @MainActor
    private static func page(_ settings: AppSettings) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 900, height: 900), dark: true, AgentSettings(pi: PiSetup.app, settings: settings))
    }

    /// The switch keeps its 30×18 drawing and has a 24pt pointer hit target.
    @MainActor
    static func switchingTrimming() async throws {
        AccessibilityNode.enable()
        let settings = AppSettings(store: ScratchDefaults())
        let window = page(settings)
        defer { window.close() }
        #expect(settings.trimToolOutput, "on until switched off")

        let control = try window.press(trim, role: ControlRole.checkBox)
        #expect(!settings.trimToolOutput, "the press turned it off")
        #expect(control.isEnabled && control.frame.width >= 26 && control.frame.height >= 16, "the switch is as big as it is drawn: \(control)")
        try window.press(trim, role: ControlRole.checkBox)
        #expect(settings.trimToolOutput, "and the next press back on")
    }

    /// The second switch of the group, pressed the same way; each changes only its own setting, and a press reads back from the store.
    @MainActor
    static func switchingDeferral() async throws {
        AccessibilityNode.enable()
        let store = ScratchDefaults()
        let settings = AppSettings(store: store)
        let window = page(settings)
        defer { window.close() }
        #expect(settings.deferTools && settings.trimToolOutput, "both on until switched off")

        let control = try window.press(defers, role: ControlRole.checkBox)
        #expect(!settings.deferTools, "the press turned it off")
        #expect(settings.trimToolOutput, "and left the trim switch alone")
        #expect(control.isEnabled && control.frame.width >= 26 && control.frame.height >= 16, "the switch is as big as it is drawn: \(control)")
        #expect(AppSettings(store: store).deferTools == false, "the choice is kept for the next launch")
        try window.press(defers, role: ControlRole.checkBox)
        #expect(settings.deferTools, "and the next press back on")
        try window.press(trim, role: ControlRole.checkBox)
        #expect(!settings.trimToolOutput && settings.deferTools, "the trim switch changes only itself")
        #expect(settings.codemode)
        window.layout()
        let codemode = try window.press("Codemode", role: ControlRole.checkBox)
        #expect(ControlPress.undersized([codemode], minimum: .desktop).isEmpty)
        #expect(!settings.codemode && settings.deferTools)
        #expect(!AppSettings(store: store).codemode)
        window.layout()
        try window.press("Codemode", role: ControlRole.checkBox)
        #expect(settings.codemode && AppSettings(store: store).codemode)
    }

    /// One menu choice per process: a native menu is chosen as a scenario's last interaction (see `NativeMenuChoice`).
    @MainActor
    static func choosingACompactionShare(from start: Int?, choosing title: String, expecting expected: Int?) async throws {
        AccessibilityNode.enable()
        let settings = AppSettings(store: ScratchDefaults())
        settings.compactAtPercent = start
        var written: [Int?] = []
        settings.onCompactAtChange = { written.append($0) }
        let window = page(settings)
        defer { window.close() }

        // Compact at is a menu: Default, then each share.
        window.layout()
        let menu = try #require(AccessibilityNode.all(under: window.host).first {
            $0.role == ControlRole.menuButton
                && "\(String(describing: $0.object.perform(NSSelectorFromString("accessibilityTitle"))?.takeUnretainedValue()))".contains("Compact at")
        }, "Compact at is a menu: \(window.controls())")
        #expect(menu.value == (start.map { "\($0)%" } ?? "Default"), "it shows the current share")
        let offered = try await NativeMenuChoice.choose(title, from: menu)
        #expect(offered == ["Default", "60%", "70%", "80%", "90%"], "pi's default, then each share")
        #expect(settings.compactAtPercent == expected, "choosing \(title)")
        #expect(written.last == .some(expected), "the choice reached the pi home: \(written)")
    }
}

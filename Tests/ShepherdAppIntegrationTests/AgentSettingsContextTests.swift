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

    @Test func compactAtOffersPisDefaultAndEachShareAndHandsTheChoiceOn() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.choosingACompactionShare() }
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
        #expect(control.isEnabled && control.frame.width >= 30 && control.frame.height >= 18, "the switch is as big as it is drawn: \(control)")
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
        #expect(control.isEnabled && control.frame.width >= 30 && control.frame.height >= 18, "the switch is as big as it is drawn: \(control)")
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

    @MainActor
    static func choosingACompactionShare() async throws {
        AccessibilityNode.enable()
        let settings = AppSettings(store: ScratchDefaults())
        var written: [Int?] = []
        settings.onCompactAtChange = { written.append($0) }
        let window = page(settings)
        defer { window.close() }

        // The picker's segments are radio buttons; their labels are the page's own, so they are found by what they say.
        let titles = ["Default", "60%", "70%", "80%", "90%"]
        func segments() -> [Control] { window.controls().filter { $0.role == ControlRole.radioButton && titles.contains($0.label ?? "") } }
        try #require(segments().map(\.label) == titles, "pi's default, then each share: \(window.controls())")
        #expect(segments().map(\.isSelected) == [true, false, false, false, false], "pi's own compaction until a share is chosen")

        for (title, expected, selected) in [("80%", 80 as Int?, 3), ("60%", 60, 1), ("90%", 90, 4), ("Default", nil, 0), ("70%", 70, 2)] {
            let pressed = try window.press(title, role: ControlRole.radioButton)
            #expect(pressed.frame.height >= 24, "\(title) is a whole segment tall: \(pressed)")
            #expect(settings.compactAtPercent == expected, "pressing \(title)")
            #expect(segments().map(\.isSelected) == (0..<5).map { $0 == selected }, "\(title) is the segment drawn chosen")
        }
        #expect(written == [80, 60, 90, nil, 70], "each choice reached the pi home, in order")
    }
}

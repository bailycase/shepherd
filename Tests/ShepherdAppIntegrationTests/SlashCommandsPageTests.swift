import AppKit
import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings ▸ Pi ▸ Slash commands, pressed the way VoiceOver presses (`ControlPress`): each
/// command's switch is a control with the command's name, pressing it turns the command off in the
/// settings the server hears, and a command that is off can be switched back on. SwiftUI draws the
/// accessibility tree only for a process an assistive client is attached to, so the scenario runs
/// in a process of its own.
@Suite("Slash commands page", .integrationTimeLimit)
struct SlashCommandsPageTests {
    @Test func everyCommandHasASwitchThatTurnsItOffAndOn() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressingTheSwitches() }
        }
    }

    @MainActor
    static func pressingTheSwitches() async throws {
        AccessibilityNode.enable()
        let settings = AppSettings(store: ScratchDefaults())
        var handed: [Set<String>] = []
        settings.onHiddenSlashCommandsChange = { handed.append($0) }
        let model = SlashCommandsModel(catalog: [
            NativeCommand(name: "session-name", description: "Set or clear session name", source: "extension"),
            NativeCommand(name: "release-notes", description: "Draft release notes", source: "prompt", arguments: "[tag]"),
            NativeCommand(name: "fix-tests", description: "Fix failing tests", source: "prompt"),
        ])
        let window = OffscreenWindow(size: CGSize(width: 900, height: 900), dark: true,
                                     ScrollView { SlashCommandsSettings(model: model, settings: settings).padding(32) }
                                         .background(Color.nw.bgWindow))
        defer { window.close() }
        window.layout()

        let switches = window.controls().filter { $0.label?.hasPrefix("/") == true }
        #expect(switches.compactMap(\.label) == ["/session-name", "/fix-tests", "/release-notes"], "one switch per command, grouped and by name: \(window.controls())")
        #expect(switches.allSatisfy { $0.role == ControlRole.checkBox && $0.isEnabled }, "each is an enabled switch: \(switches)")
        #expect(settings.hiddenSlashCommands.isEmpty, "every command starts on")
        // The shared switch is the board's 30×18pt capsule, under the desktop 24pt a control should be: it is the
        // component every Settings page uses and is left as it is (the PR names it).
        #expect(switches.allSatisfy { $0.frame.width >= 30 && $0.frame.height >= 18 }, "the whole capsule answers a click: \(switches)")

        try window.press("/fix-tests", role: ControlRole.checkBox)
        try await eventuallyOnMain("the server to be told") { handed == [["fix-tests"]] }
        #expect(settings.hiddenSlashCommands == ["fix-tests"])
        try await eventuallyOnMain("the row to say what off means") {
            window.element("/fix-tests") != nil && model.presentation.groups.flatMap(\.rows).first { $0.name == "fix-tests" }?.isOn == false
        }

        // The page lists it still, off, and the next press turns it back on.
        #expect(window.controls().contains { $0.label == "/fix-tests" })
        try window.press("/fix-tests", role: ControlRole.checkBox)
        try await eventuallyOnMain("the command to be on again") { settings.hiddenSlashCommands.isEmpty && handed.last == [] }
    }
}

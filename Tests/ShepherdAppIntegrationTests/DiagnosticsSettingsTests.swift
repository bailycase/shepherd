import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Diagnostics settings controls", .integrationTimeLimit)
struct DiagnosticsSettingsTests {
    @Test func diagnosticsRequiresConsentAndCanBeRevoked() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pressControls() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor private static func pressControls() async throws {
        AccessibilityNode.enable()
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        var changes: [Bool] = []
        settings.onDiagnosticsChange = { changes.append($0) }
        let window = OffscreenWindow(size: CGSize(width: 800, height: 400), dark: true,
            DiagnosticsSettings(settings: settings, configured: true))
        defer { window.close() }
        func toggle() -> AccessibilityNode? {
            window.elements().first { $0.label == "Share diagnostics" && ["AXCheckBox", "AXSwitch"].contains($0.role) }
        }
        try await eventuallyOnMain("the diagnostics switch") { toggle() != nil }
        let role = try #require(toggle()?.role)
        let object = try #require(toggle()?.object)
        let helpSelector = NSSelectorFromString("accessibilityHelp")
        #expect(object.responds(to: helpSelector))
        let help = object.perform(helpSelector)?.takeUnretainedValue() as? String
        #expect(help == DiagnosticsSettings.disclosure)
        let control = try window.press("Share diagnostics", role: role)
        #expect(control.frame.width >= 24 && control.frame.height >= 24)
        #expect(settings.shareDiagnostics && AppSettings(store: defaults).shareDiagnostics)
        try window.press("Share diagnostics", role: role)
        #expect(!settings.shareDiagnostics && !AppSettings(store: defaults).shareDiagnostics)
        #expect(changes == [true, false])

        let unconfigured = OffscreenWindow(size: CGSize(width: 800, height: 400), dark: false,
            DiagnosticsSettings(settings: settings, configured: false))
        defer { unconfigured.close() }
        try await eventuallyOnMain("the unconfigured switch") {
            unconfigured.controls().contains { $0.label == "Share diagnostics" }
        }
        #expect(unconfigured.controls().filter { $0.label == "Share diagnostics" }.allSatisfy { !$0.isEnabled })
    }
}

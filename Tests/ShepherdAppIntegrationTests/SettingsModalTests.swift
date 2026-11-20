import AppKit
import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@MainActor
@Suite("Settings modal", .mainActorExclusive)
struct SettingsModalTests {
    @Test func everyPageSitsInTheModalsCenteredColumnAfterNavigationAndResize() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.checkPages() }
        }
    }

    private static func checkPages() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.showSettings = true
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1100), dark: true, RootView(vm: vm))
        defer { window.close() }
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        func content() -> AccessibilityNode? {
            AccessibilityNode.all(under: window.host).first { node in
                node.object.responds(to: identifier)
                    && node.object.perform(identifier)?.takeUnretainedValue() as? String == "SettingsPageContent"
            }
        }
        for section in SettingsSection.allCases {
            for title in ["Models", "Tools", "Hooks"] {
                #expect(window.controls().contains { $0.label == title && $0.role == ControlRole.button },
                        "\(title) stays in the navigation while \(vm.settingsSection.title) is selected")
            }
            if section.parent == nil {
                let nav = try ControlPress.press(section.title, under: window.host)
                #expect(nav.isEnabled && nav.frame.width >= 24 && nav.frame.height >= 24)
            } else {
                vm.settingsSection = section
            }
            try await eventuallyOnMain("\(section.title) Settings content") {
                window.layout()
                return vm.settingsSection == section && content() != nil
            }
            for width in [1440.0, 2400.0, 1280.0] {
                window.window.setContentSize(CGSize(width: width, height: 1100))
                try await eventuallyOnMain("\(section.title) resized content") {
                    window.layout(); return abs(window.host.bounds.width - width) <= 1
                }
                let page = try #require(content(), "\(section.title) content has an accessibility container")
                let frame = window.host.convert(window.window.convertFromScreen(page.frame), from: nil)
                #expect(abs(frame.width - 620) <= 1, "\(section.title) is one 620pt column: \(frame)")
                // The 980pt modal is centered in the window; the column in the detail beside its 220pt nav.
                let modal = (width - AppLayout.settingsModalWidth) / 2
                #expect(abs(frame.midX - (modal + 220 + (AppLayout.settingsModalWidth - 220) / 2)) <= 1, "\(section.title) is centered in the modal's detail: \(frame)")
            }
        }
        // ✕ closes it.
        try ControlPress.press("Close settings", under: window.host)
        #expect(!vm.showSettings)
        vm.showSettings = true
        try await eventuallyOnMain("Settings open again") {
            window.layout(); return window.controls().contains { $0.label == "Back to Shepherd" }
        }
        // Esc: up from a sub-page, then out of Settings.
        vm.settingsSection = .fromYourPi
        try ControlPress.press("Back to Shepherd", under: window.host)
        #expect(vm.showSettings && vm.settingsSection == .models)
        try ControlPress.press("Back to Shepherd", under: window.host)
        #expect(!vm.showSettings)
    }
}

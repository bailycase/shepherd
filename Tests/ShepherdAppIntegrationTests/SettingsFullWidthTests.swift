import AppKit
import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@MainActor
@Suite("Settings full width", .mainActorExclusive)
struct SettingsFullWidthTests {
    @Test func everyPageFillsTheAvailableWidthAfterNavigationAndResize() async {
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
            for title in ["Sign-in", "Extensions", "Slash commands"] {
                #expect(window.controls().contains { $0.label == title && $0.role == ControlRole.button },
                        "\(title) stays in the navigation while \(vm.settingsSection.title) is selected")
            }
            let nav = try ControlPress.press(section.title, under: window.host)
            #expect(nav.isEnabled && nav.frame.width >= 24 && nav.frame.height >= 24)
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
                #expect(abs(frame.minX - 272) <= 1, "\(section.title) begins 40pt after the 232pt navigation: \(frame)")
                #expect(abs(frame.width - (width - 312)) <= 1,
                        "\(section.title) fills the remaining width minus two 40pt gutters: \(frame)")
            }
        }
        try ControlPress.press("Back to Shepherd", under: window.host)
        #expect(!vm.showSettings)
    }
}

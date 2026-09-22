import Foundation
import SwiftUI
import Testing
import ShepherdSessions
@testable import ShepherdApp

/// Renders every Settings page offscreen in both appearances (compared by eye against the
/// spec boards when SHEPHERD_NATIVE_SCREENSHOT_DIR is set), and checks search keywords.
@Suite("Settings pages", .serialized)
@MainActor
struct SettingsScreenshotTests {
    @Test(arguments: [false, true])
    func everyPageRenders(dark: Bool) async throws {
        let dir = URL(fileURLWithPath: "/tmp/shp-settings-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = SessionServer(socketPath: dir.appendingPathComponent("d.sock").path,
                                   stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        let vm = ShepherdViewModel(server: server)
        for section in SettingsSection.allCases {
            vm.settingsSection = section
            try await renderScreenshot(SettingsView(vm: vm), size: CGSize(width: 1440, height: 1000),
                                       name: "settings-\(section.rawValue)-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    @Test func searchFindsRowsByTitleAndKeyword() {
        #expect(SettingsSection.appearance.matches(for: "dark") == ["Mode"])
        #expect(SettingsSection.advanced.matches(for: "nightly") == ["Update channel"])
        #expect(SettingsSection.pi.matches(for: "sync") == ["Sync pi theme"])
        #expect(SettingsSection.keyboard.matches(for: "keyb") == SettingsSection.keyboard.items)
        #expect(SettingsSection.terminal.matches(for: "zzz").isEmpty)
    }
}

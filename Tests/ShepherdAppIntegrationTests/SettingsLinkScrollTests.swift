import AppKit
import Foundation
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Sign-in's Add a provider opens Settings ▸ Tools scrolled to Extensions, not at the top of the page.
@Suite("Settings links into another page", .integrationTimeLimit)
struct SettingsLinkScrollTests {
    @Test func addAProviderScrollsToolsToExtensions() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.addAProvider() }
        }
    }

    @MainActor private static func addAProvider() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.settingsSection = .models
        // Short enough that Extensions starts below the fold of Tools.
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 500), dark: false)
        defer { window.close() }
        window.show(SettingsView(vm: vm))
        ListPerf.settle(window)

        try window.press("Add a provider")

        try await eventuallyOnMain("Tools scrolls to Extensions") {
            ListPerf.settle(window)
            let offset = scrollViews(window.host).map(\.contentView.bounds.origin.y).max() ?? 0
            return vm.settingsSection == .tools && vm.settingsScrollTarget == nil && offset > 0
        }
    }

    @MainActor private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}

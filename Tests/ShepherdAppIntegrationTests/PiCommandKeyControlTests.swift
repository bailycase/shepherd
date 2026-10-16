import AppKit
import Foundation
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Unsupported command key controls", .integrationTimeLimit)
struct PiCommandKeyControlTests {
    @Test func anUnsupportedCommandKeyCanBeReplacedWithoutDisplayingOrExecutingIt() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.replaceKey() }
        }
    }

    @MainActor private static func replaceKey() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        var survey = YourPiSurvey()
        survey.logins = [.init(provider: "groq", shepherd: .apiKey(.command))]
        survey.keys = ["groq": PiKeyDisplay.of("!op read secret-not-for-display")]
        let yourPi = YourPiModel(pi: app.server.pi, survey: survey)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 1400), dark: true)
        defer { window.close() }
        window.show(PiSignInSettings(yourPi: yourPi, auth: vm.piAuth))
        ListPerf.settle(window)
        let text = AccessibilityNode.all(under: window.host).flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
        #expect(text.contains("command not supported"))
        #expect(!text.contains("secret-not-for-display"))
        let label = "Change Groq’s key"
        let button = try #require(window.controls().first { $0.label == label })
        #expect(ControlPress.undersized([button], minimum: .desktop).isEmpty)
        try window.press(label)
        #expect(vm.piAuth.session?.provider == "groq")
        #expect(vm.piAuth.session?.phase == .key)
    }
}

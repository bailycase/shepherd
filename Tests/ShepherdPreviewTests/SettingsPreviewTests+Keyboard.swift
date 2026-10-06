import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

extension SettingsPreviewTests {
    @Test func thinkingShortcutDefaultAndRebound() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.settingsSection = .keyboard
        let keys = KeybindingsStore.shared
        let original = keys.chord(for: .cycleThinkingLevel)
        defer { keys.assign(original, to: .cycleThinkingLevel) }
        for rebound in [false, true] {
            let chord = rebound ? KeyChord(key: "y", command: true, option: true) : ShortcutAction.cycleThinkingLevel.defaultChord
            #expect(keys.assign(chord, to: .cycleThinkingLevel) == nil)
            try await Preview.renderMatrix("settings-thinking-shortcut-\(rebound ? "rebound" : "default")", size: CGSize(width: 1280, height: 2400)) {
                SettingsView(vm: workspace.vm)
            }
        }
    }
}

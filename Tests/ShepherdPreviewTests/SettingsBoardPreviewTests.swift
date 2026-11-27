import AppKit
import Foundation
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Each Settings page at the size of the modal its redesign board draws (980 wide, and as tall as the board's canvas
/// less its 220pt of margin), so a render sets side by side with `<Board>@2x.png` at SHEPHERD_PREVIEW_SCALE=2.
@Suite("Settings pages against their boards", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SettingsBoardPreviewTests {
    /// The modal's height on the board: its canvas, less 110pt above and below.
    static func boardHeight(_ section: SettingsSection) -> CGFloat {
        switch section {
        case .keyboard: 1900
        case .models, .tools: 1200
        case .agents, .fleet: 1040
        case .appearance, .experiments, .fromYourPi: 860
        default: 680
        }
    }

    @Test(arguments: SettingsSection.allCases)
    func page(section: SettingsSection) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.settingsSection = section
        // The board's state: By file type set, the update rows drawn, the sidebar by space.
        vm.settings.editorsByType = [".md": "dev.zed.Zed", ".json": "com.apple.dt.Xcode"]
        vm.settings.sidebarStyle = .projects
        try await Preview.render("board-\(section.rawValue)", size: CGSize(width: AppLayout.settingsModalWidth, height: Self.boardHeight(section))) {
            SettingsView(vm: vm).environment(\.updatesPreviewAvailable, true)
        }
    }
}

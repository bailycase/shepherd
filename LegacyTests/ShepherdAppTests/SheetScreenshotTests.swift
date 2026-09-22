import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdDesign
import ShepherdSessions
@testable import ShepherdApp

/// Renders the dialogs and creation sheets offscreen in both appearances.
@Suite("Sheets", .serialized)
@MainActor
struct SheetScreenshotTests {
    @Test(arguments: [false, true])
    func sheetsRender(dark: Bool) async throws {
        let dir = URL(fileURLWithPath: "/tmp/shp-sheets-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = SessionServer(socketPath: dir.appendingPathComponent("d.sock").path,
                                   stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        let space = Space(name: "proj", path: dir.path)
        let pane = LeafPane(cwd: dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        var agent = Agent(name: "Fix the login redirect", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        agent.worktreeBranch = "shepherd/fix-login"
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = ShepherdViewModel(server: server)
        vm.selectedSpaceID = space.id
        let suffix = dark ? "dark" : "light"

        try await renderScreenshot(NewAgentSheet(vm: vm), size: CGSize(width: 620, height: 640), name: "sheet-new-agent-\(suffix)", dark: dark, settle: .milliseconds(500))
        try await renderScreenshot(NewWorktreeSheet(vm: vm, space: space), size: CGSize(width: 560, height: 420), name: "sheet-new-worktree-\(suffix)", dark: dark)
        try await renderScreenshot(FinalizeWorktreeSheet(vm: vm, agent: agent, space: space), size: CGSize(width: 560, height: 560), name: "sheet-finalize-\(suffix)", dark: dark, settle: .milliseconds(800))
        try await renderScreenshot(RenameDialog(title: "Rename agent", text: .constant("Fix the login redirect"), onRename: {}, onCancel: {}),
                                   size: CGSize(width: 420, height: 170), name: "sheet-rename-\(suffix)", dark: dark)
        let delete = DialogSheet(title: "Delete “Fix the login redirect”?", subtitle: "The agent stops and its thread is removed from Shepherd.",
                                 actions: [DialogAction("Cancel", kind: .cancel) {}, DialogAction("Delete", kind: .destructive) {}]) {
            DialogWarning(text: "3 uncommitted files and 2 unpushed commits in shepherd/fix-login will be lost.")
            SheetRow("Worktree") { Text(dir.path).font(Fonts.code).foregroundStyle(Tokens.textSecondary).lineLimit(1) }
        }
        try await renderScreenshot(delete, size: CGSize(width: 460, height: 260), name: "sheet-delete-\(suffix)", dark: dark)
    }
}

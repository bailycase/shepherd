import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings pages that read the host's stores, and a thread's account rotation notice the host sends.
extension PreviewTests {
    nonisolated static let shownInstructions = "~/Library/Application Support/Shepherd/instructions"

    @Test func localHostSettingsAndNoticeMatchTheInProcessBaseline() async throws {
        let space = Space(name: "acme-web", path: try makeScratchDirectory("acme-web").path)
        let id = AgentID()
        let pane = LeafPane(cwd: space.path, agentID: id)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: "Fix the checkout total rounding", spaceID: space.id, tabID: tab.id, paneID: pane.id,
                          status: .done, nameIsFinal: true)
        let fixture = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        let now = Date().timeIntervalSince1970
        func seed(_ server: SessionServer) throws {
            try server.instructions.save(.agents, content: SettingsPreviewTests.instructionsSample)
            try server.instructions.save(.appendSystem, content: "Never force-push to main.\n")
            try server.suggestions.configure(SuggestedInstructionsSettings(enabled: true, files: [.agents, .appendSystem]))
            _ = try server.suggestions.suggest(line: "Prefer table-driven tests in Go.", reason: "Three tests repeated one setup.",
                                               file: .agents, source: SuggestionSource(kind: .thread, name: "Ledger cleanup"),
                                               now: Date(timeIntervalSince1970: now - 7_200))
        }
        let notice = "Switched Anthropic to work: personal hit its limit."

        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        try seed(workspace.server)
        try await workspace.seed(fixture)
        workspace.server.noticeToLocalApps(agentID: id, message: notice)
        try await eventuallyOnMain("the host's notice") { vm.threadStores.existing(for: id)?.notice == notice }
        vm.selectAgent(id)
        try await Preview.render("this-mac-rotation-notice", size: CGSize(width: 1280, height: 760),
                                 ready: { vm.threadStores.existing(for: id)?.rows.isEmpty == false }) { RootView(vm: vm) }

        await vm.instructions.refresh()
        vm.settingsSection = .instructions
        // The store is in a scratch folder: show the baseline's made-up one, set
        // again after the page's own refresh, until it holds for a few polls.
        var held = 0
        try await Preview.render("this-mac-settings-instructions", size: CGSize(width: 1440, height: 900), ready: {
            guard var shown = vm.instructions.local else { return false }
            if shown.directory == Self.shownInstructions { held += 1; return held > 5 }
            shown.directory = Self.shownInstructions
            vm.instructions.localChanged(shown)
            held = 0
            return false
        }, afterReady: { held = 0 }) { SettingsView(vm: vm) }
        await vm.suggestions.refresh()
        vm.settingsSection = .experiments
        try await Preview.render("this-mac-settings-suggestions", size: CGSize(width: 1440, height: 900)) { SettingsView(vm: vm) }
        for surface in ["this-mac-rotation-notice", "this-mac-settings-instructions", "this-mac-settings-suggestions"] { try expectBaseline(surface) }
    }
}

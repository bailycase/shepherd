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

/// Settings pages that read the workspace owner's stores, and a thread's account rotation notice:
/// in process and as the background host's client, the same fixture renders the same window.
extension PreviewTests {
    nonisolated static let shownInstructions = "~/Library/Application Support/Shepherd/instructions"

    @Test func localHostSettingsAndNoticeMatchInProcess() async throws {
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

        for mode in ["in-process", "client"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: mode == "in-process")
            var host: ScratchServer?
            defer { workspace.stop(); host?.stop() }
            let vm = workspace.vm
            if mode == "in-process" {
                try seed(workspace.server)
                try await workspace.seed(fixture)
            } else {
                let made = try await adoptHost(fixture, into: workspace)
                host = made
                try seed(made.server)
                made.server.noticeToLocalApps(agentID: id, message: notice)
                try await eventuallyOnMain("the host's notice") { vm.threadStores.existing(for: id)?.notice == notice }
            }
            if mode == "in-process" { vm.threadStores.store(for: id).reportActionNotice(notice) }
            vm.selectAgent(id)
            try await Preview.render("this-mac-rotation-notice-\(mode)", size: CGSize(width: 1280, height: 760)) { RootView(vm: vm) }

            await vm.instructions.refresh()
            vm.settingsSection = .instructions
            // Each mode's store is in its own scratch folder: both show the same made-up one, set
            // again after the page's own refresh, until it holds for a few polls.
            var held = 0
            try await Preview.render("this-mac-settings-instructions-\(mode)", size: CGSize(width: 1440, height: 900), ready: {
                guard var shown = vm.instructions.local else { return false }
                if shown.directory == Self.shownInstructions { held += 1; return held > 5 }
                shown.directory = Self.shownInstructions
                vm.instructions.localChanged(shown)
                held = 0
                return false
            }, afterReady: { held = 0 }) { SettingsView(vm: vm) }
            await vm.suggestions.refresh()
            vm.settingsSection = .experiments
            try await Preview.render("this-mac-settings-suggestions-\(mode)", size: CGSize(width: 1440, height: 900)) { SettingsView(vm: vm) }
        }
        try expectSameRenders("this-mac-rotation-notice-in-process", "this-mac-rotation-notice-client")
        try expectSameRenders("this-mac-settings-instructions-in-process", "this-mac-settings-instructions-client")
        try expectSameRenders("this-mac-settings-suggestions-in-process", "this-mac-settings-suggestions-client")
    }
}

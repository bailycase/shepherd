import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

extension PreviewTests {
    /// A host whose run history file can't be read says which file and how to fix it, where the runs would be.
    @Test func automationsPageDamagedRunHistory() async throws {
        let automation = Automation(name: "Check the build", prompt: "Check build status.", cwd: "/tmp/acme")
        let key = AutomationKey(host: PageHost.localID, automation: automation.id)
        let host = AutomationHost(id: PageHost.localID, name: PageHost.localName, connected: true, manageable: true,
                                  state: ShepherdState(automations: [automation]), triggers: true)
        let root = try makeScratchDirectory("acme")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("automation-runs.json")
        try Data("{".utf8).write(to: url)
        let problem = try #require(AutomationRunLog(url: url).problem)
        let model = AutomationsPageModel.make(hosts: [host], runs: [:], selection: key, filter: "", runProblems: [key: problem])
        #expect(model.detail?.banner?.message == problem)
        try await Preview.render("page-automations-damaged-run-history",
                                 size: CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)) {
            AutomationsPage(model: model, actions: Self.noAutomationActions)
        }
    }
}

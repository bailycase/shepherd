import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdTestSupport
@testable import ShepherdApp

extension ListPerformanceTests {
    @Test func openingTheSubagentManagerBuildsOnlyVisibleDefinitions() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let store = try SubagentFixtures.store(in: app.dir)
        for index in 0..<300 {
            let text = "---\nname: helper-\(index)\ndescription: Scoped helper\ntools: [read]\n---\nInspect the assigned task.\n"
            try Data(text.utf8).write(to: store.directory.appendingPathComponent("helper-\(index).md"))
        }
        let model = SubagentDefinitionsModel(store: store)
        await model.refresh()
        vm.madeSubagentDefinitions = model; vm.settingsSection = .subagents
        let size = CGSize(width: 1440, height: 600)
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: size, dark: true, SettingsView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let onScreen = Int(size.height / AppLayout.subagentRowHeight) + 1
        #expect(model.visible.count == 304)
        #expect(rows["settings.subagent.row", default: 0] > 0, "\(rows)")
        #expect(rows["settings.subagent.row", default: 0] <= 2 * onScreen, "\(rows)")
    }
}

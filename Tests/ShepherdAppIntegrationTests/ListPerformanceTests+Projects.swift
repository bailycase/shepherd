import AppKit
import ShepherdCore
import ShepherdProtocol
import SwiftUI
import Testing
@testable import ShepherdApp

extension ListPerformanceTests {
    @Test func openingSettingsOverThreeHundredProjectsBuildsOnlyVisibleRows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let projects = (0..<300).map { index in
            ProjectSummary(directory: "/projects/\(index)", name: "Project \(index)", displayPath: "~/projects/\(index)", summary: "AGENTS.md only")
        }
        let model = ProjectsModel { _, _ in .listing(ProjectListing(projects: projects)) }
        await model.load(vm.projectsSources)
        vm.madeProjects = model; vm.settingsSection = .projects
        let size = CGSize(width: 1440, height: 600)
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: size, dark: true, SettingsView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let onScreen = Int(size.height / AppLayout.projectsRowHeight) + 1
        #expect(model.visible.count == 300)
        #expect(rows["settings.project.row", default: 0] > 0, "\(rows)")
        #expect(rows["settings.project.row", default: 0] <= 2 * onScreen, "\(rows)")
    }
}

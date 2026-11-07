import AppKit
import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// A space's Resources tab over 300 global templates: opening builds the rows on screen and some
/// ahead of them, never the whole list, and one toggle redraws its own row alone.
extension ListPerformanceTests {
    @MainActor
    @Test func oneSpaceResourceToggleRedrawsOnlyItsRow() async throws {
        let model = SpaceResourcesModel()
        await model.load(directory: "/code/payments", settingsPath: ".pi/settings.json") { request in
            switch request {
            case .resources:
                return .resources((0..<300).map { ProjectResource(kind: .prompt, name: "command-\($0 + 100)", description: "Command number \($0).",
                                                                  path: "/support/pi/prompts/command-\($0 + 100).md", global: true) })
            default: return .text(ProjectFileText(file: ProjectFile(path: ".pi/settings.json", category: .pi, exists: false), text: nil))
            }
        }
        model.kind = .prompt
        let project = ProjectsRow(host: ProjectsHost(id: "local", name: "This Mac", known: []),
                                  project: ProjectSummary(directory: "/code/payments", name: "payments", displayPath: "~/code/payments", summary: ""))
        var window: OffscreenWindow!
        let opened = ListPerf.counting {
            window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true,
                                     SpaceResourcesView(model: model, project: project).padding(32).background(Color.sh.bgWindow))
            ListPerf.settle(window)
        }
        defer { window.close() }
        #expect(opened["spaceResources.row", default: 0] > 0, "\(opened)")
        #expect(opened["spaceResources.row", default: 0] <= 40, "\(opened)")
        let row = try #require(model.rows.first)
        let changed = try await ListPerf.countingAsync {
            await model.toggle(row, on: false)
            ListPerf.settle(window)
        }
        #expect(changed["spaceResources.row", default: 0] > 0, "\(changed)")
        #expect(changed["spaceResources.row", default: 0] <= 2, "\(changed)")
    }
}

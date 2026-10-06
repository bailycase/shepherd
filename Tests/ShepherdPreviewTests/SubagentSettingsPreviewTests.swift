import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Subagent settings previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR"))
@MainActor
struct SubagentSettingsPreviewTests {
    @Test func theManagerAndEditorRenderFromOwnedMarkdownInEveryAppearance() async throws {
        for state in ["populated", "empty", "no-match", "long", "editor", "new", "error"] {
            let workspace = try PreviewWorkspace()
            defer { workspace.stop() }
            let store = try SubagentFixtures.store(in: workspace.dir, populated: true)
            let model = SubagentDefinitionsModel(store: store)
            workspace.vm.madeSubagentDefinitions = model
            workspace.vm.settingsSection = .subagents; workspace.vm.showSettings = true
            if state == "empty" {
                for row in try store.snapshot() { try store.delete(row.file, expected: try store.open(row.file).fingerprint) }
            } else if state == "long" {
                let long = "---\nname: a-long-subagent-name-for-reviewing-unusually-detailed-changes\ndescription: \(String(repeating: "Long description with paths and detailed instructions. ", count: 16))\ntools: [read]\n---\nInspect the assigned task.\n"
                try Data(long.utf8).write(to: store.directory.appendingPathComponent("api-review.md"))
            } else if state == "error" {
                try FileManager.default.moveItem(at: store.directory, to: workspace.dir.appendingPathComponent("original-agents"))
                try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: workspace.dir.appendingPathComponent("original-agents"))
            }
            await model.refresh()
            if state == "no-match" { model.filter = "nothing matches this query" }
            if state == "new" { model.create() }
            if state == "editor" { await model.open(try #require(model.definitions.first { $0.file == "api-review.md" })) }
            try await Preview.renderMatrix("subagents-\(state)", size: CGSize(width: 1440, height: 900), ready: { model.loaded && !model.busy }) {
                RootView(vm: workspace.vm)
            }
            if ["populated", "long", "editor", "new"].contains(state) {
                try await Preview.renderMatrix("subagents-\(state)-narrow", size: CGSize(width: 1050, height: 900), ready: { model.loaded && !model.busy }) {
                    RootView(vm: workspace.vm)
                }
            }
        }
    }
}

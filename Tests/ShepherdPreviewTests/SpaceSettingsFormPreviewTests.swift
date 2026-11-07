import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

/// The space Settings form (ProjectSettings, ProjectUnsaved boards) over a real space's
/// `.pi/settings.json`, with the host's global settings in Shepherd's pi home.
@Suite("Space settings form previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct SpaceSettingsFormPreviewTests {
    @Test(arguments: ["saved", "full", "dirty", "conflict", "offline", "invalid", "leave", "error"])
    func form(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let global = world.local.dir.appendingPathComponent("pi/settings.json")
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-6","defaultThinkingLevel":"medium"}"#.utf8).write(to: global)
        let model = world.vm.projects
        model.loadModels = { _ in ["anthropic/claude-sonnet-4-6", "anthropic/claude-opus-4-6", "openai/gpt-5"] }
        let project = try #require(model.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        let root = URL(fileURLWithPath: project.project.directory)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".shepherd/settings.json"))
        let file = root.appendingPathComponent(".pi/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((state == "invalid" ? "{ \"defaultModel\": " : #"{"defaultProvider":"anthropic","defaultModel":"claude-opus-4-6","defaultThinkingLevel":"high","packages":["npm:demo-tools"]}"#).utf8).write(to: file)
        await model.open(project)
        await model.navigate(.category(.pi))
        try await eventuallyOnMain("the form") { model.fileLoaded && model.formModels.count == 3 }
        let row = { (key: String) in model.formGroups.flatMap(\.rows).first { $0.key == key }! }
        switch state {
        case "dirty", "leave":
            model.setForm(row("defaultThinkingLevel"), "low")
            model.setForm(row("defaultTools"), "project")
            model.toggleFormTool("grep", on: true)
            if state == "leave" { await model.navigate(.category(.skills)) }
        case "error":
            model.setForm(row("compaction.reserveTokens"), "lots")
            model.setForm(row("shellPath"), "zsh")
        case "conflict":
            model.setForm(row("defaultThinkingLevel"), "low")
            try Data(#"{"defaultThinkingLevel":"xhigh"}"#.utf8).write(to: file)
            await model.save()
            #expect(model.conflict)
        case "offline":
            model.selected?.host.unavailable = "Host offline. Reconnect in Settings > Remote to edit its spaces."
        default: break
        }
        try await Preview.renderMatrix("space-settings-\(state)", size: CGSize(width: 1440, height: state == "full" || state == "error" ? 1800 : 900)) {
            SettingsView(vm: world.vm)
        }
    }

    /// ProjectParentSettings and ProjectChildSettings: payments holds payments-refunds; the child
    /// overrides its thinking and follows the parent's startup model.
    @Test(arguments: ["parent", "child"])
    func inheritance(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let vm = world.vm, model = vm.projects
        model.loadModels = { _ in ["anthropic/claude-sonnet-4-6", "anthropic/claude-opus-4-6"] }
        let payments = try #require(model.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        let root = URL(fileURLWithPath: payments.project.directory)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".shepherd/settings.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        try Data(#"{"defaultProvider":"anthropic","defaultModel":"claude-opus-4-6","defaultThinkingLevel":"high"}"#.utf8).write(to: root.appendingPathComponent(".pi/settings.json"))
        let child = root.appendingPathComponent("refunds")
        try FileManager.default.createDirectory(at: child.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        try Data(#"{"defaultThinkingLevel":"low"}"#.utf8).write(to: child.appendingPathComponent(".pi/settings.json"))
        _ = try await vm.handleProjectRequest(.register(path: child.path, name: "payments-refunds"))
        let row = try #require(model.rows.first { $0.project.name == (state == "child" ? "payments-refunds" : "payments") && $0.host.id == "local" })
        await model.open(row)
        await model.navigate(.category(.pi))
        try await eventuallyOnMain("the form") { model.fileLoaded && !model.formGroups.isEmpty && (state == "parent" || model.context.parentName != nil) }
        try await Preview.renderMatrix("space-settings-\(state)", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
        }
    }
}

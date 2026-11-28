import AppKit
import Foundation
import ShepherdSessions
import ShepherdTestSupport
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
        let workspace = try PreviewWorkspace(mcp: section == .tools ? try await MCPPreviewFixtures.boardStore() : nil)
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

    /// Spaces (SettingsSpaces): the list, and one space open (SettingsSpace).
    @Test func spaces() async throws {
        let world = try await ProjectsPreviewWorld()
        defer { world.stop() }
        world.vm.settingsSection = .projects
        let size = CGSize(width: AppLayout.settingsModalWidth, height: AppLayout.settingsModalHeight)
        try await Preview.render("board-spaces", size: size) { SettingsView(vm: world.vm) }
    }

    @Test func spaceOpen() async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        world.vm.settingsSection = .projects
        let project = try #require(world.vm.projects.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        await world.vm.projects.open(project)
        try await Preview.render("board-space", size: CGSize(width: AppLayout.settingsModalWidth, height: 860)) { SettingsView(vm: world.vm) }
    }

    /// Agents ▸ Profiles (SettingsSubagents) and one profile open (SettingsSubagentEdit), from the board's four profiles.
    @Test(arguments: ["list", "edit"])
    func subagents(_ state: String) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let store = try SubagentFixtures.store(in: workspace.dir, populated: false)
        let profiles: [(String, String, String, String, String)] = [
            ("scout", "Find code and facts", "gpt-6-luna", "[read, grep, find, ls]", "Find code and facts. Report what you found with paths."),
            ("reviewer", "Review for correctness and security.", "gpt-6.1-sol", "[read, grep, find, ls]",
             "Review for correctness and security.\n\nReport actionable findings with paths and evidence.\n\nDo not edit files."),
            ("planner", "A bounded plan before edits", "gpt-6-astra", "[read, grep, find, ls]", "Write a bounded plan before any edits."),
            ("worker", "Implements one task", "claude-sonnet-5-5", "[read, grep, find, ls, bash, edit, write]", "Implement the assigned task.")]
        for (name, description, model, tools, prompt) in profiles {
            let text = "---\nname: \(name)\ndescription: \(description)\nmodel: \(model)\nthinking: high\ntools: \(tools)\n---\n\(prompt)\n"
            try Data(text.utf8).write(to: store.directory.appendingPathComponent("\(name).md"))
        }
        let model = SubagentDefinitionsModel(store: store)
        workspace.vm.madeSubagentDefinitions = model
        workspace.vm.settingsSection = .subagents
        await model.refresh()
        if state == "edit" { await model.open(try #require(model.definitions.first { $0.file == "reviewer.md" })) }
        try await Preview.render("board-subagents-\(state)", size: CGSize(width: AppLayout.settingsModalWidth, height: AppLayout.settingsModalHeight),
                                 ready: { model.loaded && !model.busy }) {
            SettingsView(vm: workspace.vm)
        }
        // The whole page, which the board's 680pt window cuts off under its extra rows.
        if state == "edit" {
            try await Preview.render("board-subagents-edit-tall", size: CGSize(width: AppLayout.settingsModalWidth, height: 1100),
                                     ready: { model.loaded && !model.busy }) {
                SettingsView(vm: workspace.vm)
            }
        }
    }

    /// Instructions ▸ AGENTS.md with an unsaved edit (SettingsInstructionsEdit).
    @Test func instructionsEdit() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let text = """
        # How I work

        - Prefer pnpm over npm. Use nix, not venvs.
        - Smallest change that solves the problem.
        - Reuse local patterns before adding new ones.

        ## UI work

        - A board the user sends is the spec.
        - Render light and dark before calling it done.

        ## Git

        - Branches: feat/… or fix/… off main.
        - Conventional commits, no AI attribution.

        ## Tests

        - Protect real behavior, not coverage.
        - Investigate a failing test before changing it.

        """
        try workspace.server.instructions.save(.agents, content: text)
        try await workspace.seed(workspace.server.state)
        let model = workspace.vm.instructions
        await model.refresh()
        model.setText(text.replacingOccurrences(of: "Smallest change", with: "The smallest change"), file: .agents)
        workspace.vm.settingsSection = .instructions
        model.editing = true
        try await Preview.render("board-instructions-edit", size: CGSize(width: AppLayout.settingsModalWidth, height: AppLayout.settingsModalHeight)) {
            SettingsView(vm: workspace.vm)
        }
    }

    /// Tools ▸ linear open (SettingsToolsServer), at its board's 680pt window.
    @Test func toolsServer() async throws {
        let store = try await MCPPreviewFixtures.boardStore()
        let workspace = try PreviewWorkspace(mcp: store)
        defer { workspace.stop() }
        workspace.vm.mcpOpenServer = "linear"
        workspace.vm.settingsSection = .tools
        try await Preview.render("board-tools-server", size: CGSize(width: AppLayout.settingsModalWidth, height: AppLayout.settingsModalHeight)) {
            SettingsView(vm: workspace.vm)
        }
    }
}


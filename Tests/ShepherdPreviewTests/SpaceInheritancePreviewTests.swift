import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

/// MCP servers and skills a child space inherits (ProjectParentMCP, ProjectChildMCP,
/// ProjectTestingMCP, ProjectChildMCPOverride, ProjectChildSkills boards): payments holds
/// payments-landing, which adds its own server and skill, and payments-testing, which adds nothing.
@Suite("Space inheritance previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct SpaceInheritancePreviewTests {
    @Test(arguments: ["parent-mcp", "child-mcp", "testing-mcp", "child-mcp-override", "child-mcp-disabled", "child-skills", "child-skills-override",
                            "child-commands", "child-extensions"])
    func inheritance(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let vm = world.vm, fm = FileManager.default
        // The approval check runs pi's SDK, which the preview sandbox doesn't stage: answer it as an added space's host does.
        let local = world.local.server
        let model = ProjectsModel { host, request in
            if case .mcp(_, _, .credentials) = request { return .mcp(.init(projectTrusted: true)) }
            if host.id == "local" { return try await local.projects.request(request, state: local.state) }
            return try await vm.remoteHosts.projects(hostID: UUID(uuidString: host.id)!, endpointID: host.endpointID, request: request)
        }
        vm.madeProjects = model
        await model.load(vm.projectsSources)
        let payments = try #require(model.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        let root = URL(fileURLWithPath: payments.project.directory)
        func write(_ folder: URL, _ relative: String, _ text: String) throws {
            let url = folder.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func skill(_ name: String, _ description: String) -> String { "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n" }
        try? fm.removeItem(at: root.appendingPathComponent(".shepherd/skills"))
        try write(root, ".shepherd/mcp.json", #"{"mcpServers":{"github":{"command":"npx","args":["@modelcontextprotocol/server-github"],"env":{"GITHUB_TOKEN":"$GITHUB_TOKEN"}},"docs":{"url":"https://docs.example.invalid/mcp"}}}"#)
        try write(root, ".pi/skills/payments-review/SKILL.md", skill("payments-review", "Review changes against the payments space rules."))
        try write(world.local.dir, "pi/skills/useful-tests/SKILL.md", skill("useful-tests", "Choose useful checks for observable behavior."))
        let landing = root.appendingPathComponent("landing"), testing = root.appendingPathComponent("testing")
        try write(landing, ".shepherd/mcp.json", state == "child-mcp-override"
                  ? #"{"mcpServers":{"docs":{"url":"https://landing.example.invalid/mcp"},"playwright":{"command":"npx","args":["@playwright/mcp"]}}}"#
                  : #"{"mcpServers":{"playwright":{"command":"npx","args":["@playwright/mcp"]}}}"#)
        try write(landing, ".pi/skills/landing-copy/SKILL.md", skill("landing-copy", "Review landing-page copy and links."))
        try fm.createDirectory(at: testing, withIntermediateDirectories: true)
        try write(root, ".pi/prompts/ship.md", "---\ndescription: Cut a payments release.\n---\nShip $1.\n")
        try write(root, ".pi/prompts/refund-check.md", "---\ndescription: Check a refund against the ledger.\n---\nCheck.\n")
        try write(landing, ".pi/prompts/landing-copy.md", "---\ndescription: Review the landing page copy.\n---\nReview.\n")
        try write(landing, ".pi/extensions/analytics.ts", "// Sends page events to the landing dashboard.\nexport default function analytics() {}\n")
        _ = try await vm.handleProjectRequest(.register(path: landing.path, name: "payments-landing"))
        _ = try await vm.handleProjectRequest(.register(path: testing.path, name: "payments-testing"))
        let name = state.hasPrefix("parent") ? "payments" : state.hasPrefix("testing") ? "payments-testing" : "payments-landing"
        let row = try #require(model.rows.first { $0.project.name == name && $0.host.id == "local" })
        await model.open(row)
        if state == "child-commands" || state == "child-extensions" {
            await model.navigate(.category(.skills))
            model.resources.kind = state == "child-commands" ? .prompt : .extension
            try await eventuallyOnMain("the inherited \(state)") { model.resources.rows.contains { $0.inheritedFrom != nil } }
            // One inherited item turned off for this child only, through the host's record.
            if let first = model.resources.rows.first(where: { $0.inheritedFrom != nil }) {
                await model.resources.toggle(first, on: false)
                try await eventuallyOnMain("the turned-off row") { model.resources.rows.contains { $0.inheritedFrom != nil && !$0.enabled } }
            }
        } else if state.contains("skills") {
            await model.navigate(.category(.skills))
            try await eventuallyOnMain("the inherited skills") { model.resources.rows.contains { $0.inheritedFrom != nil } }
            if state == "child-skills-override", let inherited = model.resources.rows.first(where: { $0.inheritedFrom != nil }) {
                await model.resources.overrideInherited(inherited)
                #expect(model.resources.rows.contains { $0.overrides == "payments" })
            }
        } else {
            await model.navigate(.category(.mcp))
            try await eventuallyOnMain("the servers") { model.fileLoaded && (state.hasPrefix("parent") ? model.inheritingChildCount == 2 : model.parentMCP != nil) }
            if state == "child-mcp-disabled" {
                await model.setInherited(mcp: "docs", on: false)
                #expect(model.isExcluded(mcp: "docs"))
            }
        }
        try await Preview.renderMatrix("space-inheritance-\(state)", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
        }
    }

    /// The space's Settings on a paired Mac: the Parent space row lists that host's spaces, and an
    /// older host says why it can't change.
    @Test(arguments: ["remote-parent", "remote-older"])
    func remoteParent(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true, remoteCapabilities: state == "remote-older"
            ? RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.projectParentCapability } : nil)
        defer { world.stop() }
        let home = URL(fileURLWithPath: world.remote.server.pi.userHome)
        let payments = Space(name: "payments", path: home.appendingPathComponent("code/payments").path)
        let docs = Space(name: "payments-docs", path: home.appendingPathComponent("code/payments-docs").path,
                         parentID: payments.id, parentIsExplicit: state == "remote-parent")
        for space in [payments, docs] { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
        try await world.remote.server.putState(ShepherdState(spaces: [payments, docs]))
        try await eventuallyOnMain("the host's spaces") { world.vm.remoteHosts.connections.first?.state.spaces.count == 2 }
        let model = world.vm.projects
        await model.load(world.vm.projectsSources, force: true)
        let row = try #require(model.rows.first { $0.project.name == "payments-docs" && $0.host.id != "local" })
        await model.open(row)
        await model.navigate(.category(.pi))
        try await eventuallyOnMain("the settings form") { model.fileLoaded }
        if state == "remote-parent" {
            #expect(model.parentSpaceName == "payments" && model.parentChoices.map(\.name) == ["payments"])
        } else {
            #expect(model.parentProblem == "Update Shepherd on Build-01 to choose a parent space.")
        }
        try await Preview.renderMatrix("space-\(state)", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
        }
    }
}

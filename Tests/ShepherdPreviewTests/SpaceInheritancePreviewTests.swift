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
    @Test(arguments: ["parent-mcp", "child-mcp", "testing-mcp", "child-mcp-override", "child-mcp-disabled", "child-skills", "child-skills-override"])
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
        _ = try await vm.handleProjectRequest(.register(path: landing.path, name: "payments-landing"))
        _ = try await vm.handleProjectRequest(.register(path: testing.path, name: "payments-testing"))
        let name = state.hasPrefix("parent") ? "payments" : state.hasPrefix("testing") ? "payments-testing" : "payments-landing"
        let row = try #require(model.rows.first { $0.project.name == name && $0.host.id == "local" })
        await model.open(row)
        if state.contains("skills") {
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
}

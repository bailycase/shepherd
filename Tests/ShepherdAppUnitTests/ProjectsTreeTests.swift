import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

/// Settings ▸ Projects as a tree (SettingsProjects, parents and subprojects): subprojects under their
/// parent by folder, their MCP servers counted as inherited and local, and the filter and the
/// disclosure keeping the tree readable.
@Suite("Projects tree", .mainActorExclusive)
@MainActor
struct ProjectsTreeTests {
    private static let listing = [
        ProjectSummary(directory: "/code/acme", name: "acme", displayPath: "~/code/acme", summary: "AGENTS.md · 2 MCP", mcpServers: ["docs", "shared"]),
        ProjectSummary(directory: "/code/payments", name: "payments", displayPath: "~/code/payments", summary: "3 skills · 2 MCP servers", mcpServers: ["a", "b"]),
        ProjectSummary(directory: "/code/acme/apps/web", name: "web", displayPath: "~/code/acme/apps/web", summary: "1 MCP",
                       parent: "/code/acme", mcpServers: ["local"], inheritedMCP: ["docs", "shared"]),
        ProjectSummary(directory: "/code/acme/apps/admin", name: "admin", displayPath: "~/code/acme/apps/admin", summary: "no project settings",
                       parent: "/code/acme", inheritedMCP: ["docs", "shared"]),
    ]

    private func loaded() async -> ProjectsModel {
        let model = ProjectsModel { _, _ in .listing(ProjectListing(projects: Self.listing)) }
        await model.load([ProjectsHost(id: "local", name: "This Mac", known: [])])
        return model
    }

    @Test func subprojectsSitUnderTheirParentWithItsMCPCountedTheBoardsWay() async {
        let model = await loaded()
        #expect(model.visible.map(\.project.name) == ["acme", "web", "admin", "payments"])
        #expect(model.visible[0].children == 2)
        #expect(model.visible[0].configuration == "2 shared MCP servers")
        #expect(model.visible[1].parentName == "acme")
        #expect(model.visible[1].configuration == "2 inherited · 1 local MCP")
        #expect(model.visible[2].configuration == "2 inherited MCP servers")
        #expect(model.visible[3].configuration == "3 skills · 2 MCP servers", "a project with no subprojects keeps its summary")
        #expect(model.countText == "4 projects")
    }

    @Test func collapsingAParentFoldsItsSubprojectsAndAFilterStillFindsThem() async {
        let model = await loaded()
        model.collapsed = [model.visible[0].id]
        #expect(model.visible.map(\.project.name) == ["acme", "payments"])
        model.filter = "admin"
        #expect(model.visible.map(\.project.name) == ["acme", "admin"], "a match keeps its parent above it, folded or not")
        model.filter = "acme"
        #expect(model.visible.map(\.project.name) == ["acme", "web", "admin"], "a matching parent keeps its subprojects")
    }

    @Test func aSubprojectWhoseParentIsntListedStandsAlone() async {
        let orphan = ProjectSummary(directory: "/code/gone/app", name: "app", displayPath: "~/code/gone/app", summary: "1 MCP",
                                    parent: "/code/gone", mcpServers: ["x"])
        let rows = ProjectsRow.tree([ProjectsRow(host: ProjectsHost(id: "local", name: "This Mac", known: []), project: orphan)])
        #expect(rows.count == 1 && !rows[0].isSubproject && rows[0].configuration == "1 MCP")
    }
}

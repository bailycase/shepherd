import Foundation
import Testing
@testable import ShepherdSessions

/// The Context card names the system prompt's tools by group. The host knows a tool by its name alone, so
/// `ContextToolGroups` reads the group off it, and `Tests/Extensions/context-tools.json` (the audit of every tool
/// Shepherd registers, which the Node tests check against a real pi) is what it must agree with.
@Suite("Context tool groups")
struct ContextToolGroupsTests {
    private struct Registry: Decodable {
        struct Family: Decodable {
            var tools: [String]
            var group: String
        }

        var groups: [String: String]
        var families: [Family]
    }

    private static func registry() throws -> Registry {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/context-tools.json")
        return try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url))
    }

    @Test func everyRegisteredToolIsInTheGroupTheAuditGivesIt() throws {
        let registry = try Self.registry()
        #expect(registry.families.count >= 15)
        for family in registry.families {
            for tool in family.tools {
                #expect(ContextToolGroups.id(forTool: tool) == family.group, "\(tool)")
                #expect(ContextToolGroups.label(forTool: tool) == registry.groups[family.group], "\(tool)")
            }
        }
    }

    @Test func theLabelsAreTheAuditsGroups() throws {
        #expect(ContextToolGroups.labels == (try Self.registry()).groups)
    }

    /// A tool no row lists (one of the user's extensions) is "other tools".
    @Test(arguments: ["github_search_code", "linear_create_issue", "my_extension_tool", "mcp", "xmcp__a__b", ""])
    func aToolNoRowListsIsOther(_ name: String) {
        #expect(ContextToolGroups.label(forTool: name) == "other tools")
    }

    /// pi's own MCP: its search and resource tools, and the tools of a server set to Direct, are "MCP".
    @Test(arguments: ["tool_search", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource", "mcp__github__search_code", "mcp__a__b"])
    func piMCPToolsAreMCP(_ name: String) {
        #expect(ContextToolGroups.id(forTool: name) == "mcp")
        #expect(ContextToolGroups.label(forTool: name) == "MCP")
    }
}

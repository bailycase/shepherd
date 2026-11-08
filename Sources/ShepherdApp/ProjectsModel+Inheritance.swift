import Foundation
import ShepherdProtocol
import ShepherdUI

/// MCP servers and skills a child space inherits from the space whose folder holds it
/// (ProjectChildMCP, ProjectChildMCPOverride, ProjectChildSkills boards), and the parent's side
/// (ProjectParentMCP). A child turns an inherited one off for itself in Shepherd's own record on the
/// host (`RemoteProjectsRequest.inheritance`), or overrides it with its own copy; it never writes
/// the parent's files.
extension ProjectsModel {
    /// The space this one inherits from, as the host resolves it at launch.
    var inheritanceParent: ProjectsRow? {
        guard let selected, let directory = context.inheritsFrom else { return nil }
        return rows.first { $0.host.id == selected.host.id && $0.project.directory == directory }
    }

    var inheritanceParentName: String? {
        context.inheritsFrom.map { inheritanceParent?.project.name ?? URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Spaces on the same host whose servers and skills come from this one.
    var inheritingChildCount: Int {
        guard let selected else { return 0 }
        let folders = rows.filter { $0.host.id == selected.host.id }.map(\.project.directory)
        return rows.filter { $0.host.id == selected.host.id && ProjectNesting.parent(of: $0.project.directory, among: folders) == selected.project.directory }.count
    }

    /// Turning inherited items off needs a host that records it (`projectInheritanceCapability`).
    var canExcludeInherited: Bool {
        selected?.host.supportsInheritance == true && selected?.unavailable == nil && context.excluded != nil && !saving
    }

    /// The parent's servers, from both of its MCP files with `.shepherd` winning, as
    /// `shepherd-mcp-parent.ts` reads them.
    func loadParentMCP() async {
        guard let selected, let parent = context.inheritsFrom else { parentMCP = nil; return }
        var servers: [String: JSONValue] = [:]
        var order: [String] = []
        for file in [".pi/mcp.json", ".shepherd/mcp.json"] {
            guard case .text(let value)? = try? await request(selected.host, .read(directory: parent, file: file)), let text = value.text else { continue }
            for entry in ProjectMCPConfiguration(text: text, path: file).entries {
                if servers[entry.name] == nil { order.append(entry.name) }
                servers[entry.name] = .object(entry.json)
            }
        }
        guard self.selected?.id == selected.id else { return }
        let text = MCPConfigDocument(root: ["mcpServers": .object(servers)], order: order).text
        parentMCP = ProjectMCPConfiguration(text: text, host: selected.host.name)
    }

    func isExcluded(mcp name: String) -> Bool { context.excluded?.mcp.contains(name) == true }
    func isExcluded(skill name: String) -> Bool { context.excluded?.skills.contains(name) == true }

    /// Turns one inherited server or skill on or off for this space only.
    func setInherited(mcp: String? = nil, skill: String? = nil, on: Bool) async {
        guard canExcludeInherited, let selected, var excluded = context.excluded else { return }
        if let mcp { excluded.mcp.removeAll { $0 == mcp }; if !on { excluded.mcp.append(mcp) } }
        if let skill { excluded.skills.removeAll { $0 == skill }; if !on { excluded.skills.append(skill) } }
        do {
            guard case .context(let next) = try await request(selected.host, .inheritance(directory: selected.project.directory, excluded: excluded)) else {
                throw ProjectFileError("protocol", "Unexpected space context reply.")
            }
            if self.selected?.id == selected.id { context = next }
        } catch {
            if skill != nil { resources.message = String(describing: error) } else { fileError = String(describing: error) }
        }
    }

    /// Override here: the parent's entry, copied into this space's MCP file, where it wins by name.
    func overrideMCP(_ name: String) async {
        guard let entry = parentMCP?.entries.first(where: { $0.name == name }) else { return }
        do { try await saveMCP([entry]) } catch { fileError = String(describing: error) }
    }

    /// Opens the parent space on the same tab.
    func openInheritanceParent() async {
        guard let parent = inheritanceParent else { return }
        let tab = category
        await navigate(.close)
        guard selected == nil else { return }
        await open(parent)
        if tab != .instructions { await navigate(.category(tab)) }
    }
}

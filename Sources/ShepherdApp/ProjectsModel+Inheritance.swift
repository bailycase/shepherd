import ShepherdSessions
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// MCP servers, skills, slash commands and extensions a child space inherits from the space whose folder holds it
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

    /// Turns one inherited server on or off for this space only.
    func setInherited(mcp: String, on: Bool) async {
        guard var excluded = context.excluded else { return }
        excluded.mcp.removeAll { $0 == mcp }; if !on { excluded.mcp.append(mcp) }
        await saveExclusions(excluded, resource: false)
    }

    /// Turns one inherited skill, slash command or extension on or off for this space only.
    func setInherited(_ kind: ProjectResource.Kind, _ name: String, on: Bool) async {
        guard var excluded = context.excluded else { return }
        func set(_ list: inout [String]) { list.removeAll { $0 == name }; if !on { list.append(name) } }
        switch kind {
        case .skill: set(&excluded.skills)
        case .prompt: set(&excluded.prompts)
        case .extension: set(&excluded.extensions)
        case .agent: return
        }
        await saveExclusions(excluded, resource: true)
    }

    private func saveExclusions(_ excluded: SpaceInheritanceExclusions, resource: Bool) async {
        guard canExcludeInherited, let selected else { return }
        do {
            guard case .context(let next) = try await request(selected.host, .inheritance(directory: selected.project.directory, excluded: excluded)) else {
                throw ProjectFileError("protocol", "Unexpected space context reply.")
            }
            if self.selected?.id == selected.id { context = next }
        } catch {
            if resource { resources.message = String(describing: error) } else { fileError = String(describing: error) }
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

/// The space's parent space (Settings tab), as Add space sets it: Shepherd's organization
/// (`Space.parentID`), on this Mac or another host with `projectParentCapability`.
extension ProjectsModel {
    /// Why the parent can't be changed here, or nil when it can.
    var parentProblem: String? {
        guard let selected else { return "" }
        if selected.unavailable != nil { return "Host offline. Reconnect to change the parent space." }
        if selected.host.id != "local", !selected.host.supportsParent { return "Update Shepherd on \(selected.host.name) to choose a parent space." }
        if selected.project.projectID == nil { return "Add this folder as a space to choose its parent." }
        return nil
    }

    var parentSpaceName: String? {
        guard let selected, let parent = selected.project.parent else { return nil }
        return rows.first { $0.host.id == selected.host.id && $0.project.directory == parent }?.project.name
    }

    /// Spaces on the same host that can hold this one: never itself or one of its own child spaces.
    var parentChoices: [AddSpaceModel.Parent] {
        guard let selected else { return [] }
        let same = rows.filter { $0.host.id == selected.host.id }
        let byDirectory = Dictionary(same.map { ($0.project.directory, $0.project.parent) }, uniquingKeysWith: { first, _ in first })
        func descends(_ directory: String) -> Bool {
            var cursor: String? = directory, steps = 0
            while let current = cursor, steps < 32 {
                if current == selected.project.directory { return true }
                cursor = byDirectory[current] ?? nil; steps += 1
            }
            return false
        }
        return same.compactMap { row in
            guard let id = row.project.projectID, !descends(row.project.directory) else { return nil }
            return AddSpaceModel.Parent(id: id, name: row.project.name)
        }
    }

    /// Saves at once, like turning an inherited server off: it is Shepherd's record, not a space file.
    func setParent(_ parentID: SpaceID?) async {
        guard parentProblem == nil, !settingParent, let selected, let id = selected.project.projectID else { return }
        settingParent = true; parentError = nil
        defer { settingParent = false }
        do {
            _ = try await request(selected.host, .organize(spaceID: id, name: nil, parentID: parentID))
            await load(hosts, force: true)
        } catch { parentError = String(describing: error) }
    }
}

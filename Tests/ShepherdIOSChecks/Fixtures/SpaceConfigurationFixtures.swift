import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension FixtureCatalog {
    static var spaceConfiguration: [FixtureScreen] {
        let root = "/demo/acme/acme-web"
        let parent = "/demo/acme"
        let name = "acme-web"
        let space = Space(id: SpaceID(rawValue: "space-acme-web"), name: name, path: root)
        let agents = ProjectFile(path: "AGENTS.md", category: .instructions, exists: true)
        let settings = ProjectFile(path: ".shepherd/settings.json", category: .pi, exists: true)
        let mcp = ProjectFile(path: ".shepherd/mcp.json", category: .mcp, exists: true)
        let skill = ProjectResource(kind: .skill, name: "checkout-review", description: "Review checkout changes.", path: ".pi/skills/checkout-review/SKILL.md")
        let inherited = ProjectResource(kind: .skill, name: "release-notes", description: "Draft notes from the changelog.", path: ".pi/skills/release-notes/SKILL.md")
        let host = FixtureHostData(id: FixtureData.studio, name: "acme-studio", state: ShepherdState(spaces: [space]), reply: { request in
            guard case .projects(let id, let action) = request else { return nil }
            let result: RemoteProjectsResult
            switch action {
            case .list:
                result = .listing(.init(projects: [.init(directory: root, name: name, displayPath: root, summary: "AGENTS.md · 1 skill")]))
            case .files(let folder) where folder == root:
                result = .files([agents, settings, mcp, .init(path: skill.path, category: .skills, exists: true)])
            case .context(let folder) where folder == root:
                result = .context(.init(resources: 1, mcpServers: 1, inheritsFrom: parent, excluded: .init()))
            case .read(let folder, let path) where folder == root && path == agents.path:
                result = .text(.init(file: agents, text: "# acme-web\n\n- Run tests before a PR.\n- Use integer cents for totals.\n"))
            case .read(let folder, let path) where path.hasSuffix("mcp.json"):
                let text = folder == root ? #"{"mcpServers":{"catalog":{"url":"https://catalog.example.com/mcp"}}}"#
                    : path == mcp.path ? #"{"mcpServers":{"docs":{"url":"https://docs.example.com/mcp"}}}"# : nil
                result = .text(.init(file: .init(path: path, category: .mcp, exists: text != nil), text: text))
            case .mcp(_, _, .credentials):
                result = .mcp(.init())
            case .resources(let folder):
                result = .resources(folder == root ? [skill] : [inherited])
            default: return nil
            }
            return .projects(id: id, result: result)
        })
        func routes(_ section: SpaceConfigurationSection? = nil) -> [MobileRoute] {
            [.settings(.root), .settings(.spaces), .settings(.spaceConfiguration(host: host.id, directory: root, name: name, section: section))]
        }
        return [
            FixtureScreen(name: "space-configuration", hosts: [host], routes: routes(), tab: .settings),
            FixtureScreen(name: "space-configuration-skills", hosts: [host], routes: routes(.skills), tab: .settings),
            FixtureScreen(name: "space-configuration-mcp", hosts: [host], routes: routes(.mcp), tab: .settings),
        ]
    }
}

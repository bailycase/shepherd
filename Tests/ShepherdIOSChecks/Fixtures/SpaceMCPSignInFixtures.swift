import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

@MainActor extension FixtureCatalog {
    static var spaceMCPSignIn: [FixtureScreen] {
        [spaceMCP(FixtureScreen(name: "space-mcp-sign-in-ready"), phase: .done),
         spaceMCP(FixtureScreen(name: "space-mcp-sign-in-waiting"), phase: .waiting),
         spaceMCP(FixtureScreen(name: "space-mcp-sign-in-failed"), phase: .failed)]
    }

    private static func spaceMCP(_ fixture: FixtureScreen, phase: ProjectMCPResult.Phase) -> FixtureScreen {
        let directory = "/work/acme-web"
        let file = ProjectFile(path: ".shepherd/mcp.json", category: .mcp, exists: true)
        let run = UUID()
        let text = #"{"mcpServers":{"acme-issues":{"url":"https://issues.example.invalid/mcp"},"acme-docs":{"url":"https://docs.example.invalid/mcp"}}}"#
        let host = FixtureHostData(id: FixtureData.studio, name: "Acme Studio",
                                   state: ShepherdState(spaces: [Space(name: "acme-web", path: directory)]),
                                   projectReply: { request in
            guard case .projects(let id, let action) = request else { return nil }
            let result: RemoteProjectsResult
            switch action {
            case .files: result = .files([file])
            case .read: result = .text(.init(file: file, text: text))
            case .context: result = .context(.init(files: [], resources: 0, mcpServers: 2))
            case .mcp(_, _, .credentials): result = .mcp(.init(signedIn: ["acme-docs"]))
            case .mcp(_, _, .login), .mcp(_, _, .poll):
                result = .mcp(.init(id: run, phase: phase, message: phase == .failed ? "The MCP server couldn't complete sign-in." : nil))
            default: return nil
            }
            return .projects(id: id, result: result)
        })
        return FixtureScreen(name: fixture.name, hosts: [host], routes: [.settings(.spaces), .settings(.space(directory))], tab: .settings,
                             prepare: { _ in
            await FixtureWindows.wait("space MCP sign-in requests", seconds: 10) {
                let count = FixtureHost.running(host.id)?.requests.filter { $0 == "projects" }.count ?? 0
                return count >= (phase == .done ? 4 : 6)
            }
        }, setup: { SpaceMCP.fixtureServer = phase == .done ? nil : "acme-issues" })
    }
}

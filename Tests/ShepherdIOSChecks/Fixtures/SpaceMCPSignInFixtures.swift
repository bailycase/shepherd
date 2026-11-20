import Foundation
import UIKit
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
            case .list: result = .listing(.init(projects: [.init(directory: directory, name: "acme-web", displayPath: directory, summary: "")]))
            case .files: result = .files([file])
            case .read: result = .text(.init(file: file, text: text))
            case .context: result = .context(.init(files: [], resources: 0, mcpServers: 2))
            case .mcp(_, _, .credentials): result = .mcp(.init(signedIn: ["acme-docs"]))
            case .mcp(_, _, .cancel): result = .mcp(.init())
            case .mcp(_, _, .login), .mcp(_, _, .poll):
                result = .mcp(.init(id: run, phase: phase, message: phase == .failed ? "The MCP server couldn't complete sign-in." : nil))
            default: return nil
            }
            return .projects(id: id, result: result)
        })
        return FixtureScreen(name: fixture.name, hosts: [host], routes: [
            .settings(.root), .settings(.spaces),
            .settings(.spaceConfiguration(host: host.id, directory: directory, name: "acme-web", section: .mcp)),
        ], tab: .settings, prepare: { _ in
            SidebarAutomationsCheck.enableAccessibility()
            await FixtureCheck.wait("the enabled space MCP sign-in button", seconds: 8) {
                TriggerFlowCheck.element("Sign in")?.accessibilityTraits.contains(.notEnabled) == false
            }
            guard phase != .done else { return }
            await TriggerFlowCheck.press("Sign in")
            let label = phase == .failed ? "The MCP server couldn't complete sign-in." : "Cancel"
            await FixtureCheck.wait(label, seconds: 8) { TriggerFlowCheck.element(label) != nil }
        })
    }
}

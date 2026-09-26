import AppKit
import Foundation
import ShepherdProtocol
import ShepherdSessions

extension ShepherdViewModel {
    /// The MCP client agents run, installed beside the MCP extension in the support directory.
    /// Settings' probes run the same file with node.
    nonisolated static func mcpClientPath() -> URL? {
        let url = ShepherdPaths.supportDirectory().appendingPathComponent("shepherd-mcp-client.mjs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Answers the MCP extension's credential requests and keeps its reports, both through
    /// `MCPStore`. A needs-sign-in answer opens the sign-in sheet when Settings says so.
    func wireMCP() {
        server.onMCPRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let mcp = self?.mcp else {
                    respond(.failure(code: MCPFailureCode.unavailable, message: "Shepherd is closing."))
                    return
                }
                Task { @MainActor in respond(await mcp.credentials(for: request)) }
            }
        }
        server.onMCPReport = { [weak self] agentID, report in
            MainActor.assumeIsolated { self?.mcp.receive(report, from: agentID) }
        }
        mcp.onNeedsSignIn = { [weak self] name in
            guard let self, self.settings.mcpOpenSignInPages, self.mcp.signIn == nil else { return }
            self.openMCPSettings()
            self.mcp.beginSignIn(name)
        }
    }

    /// Settings ▸ MCP servers.
    func openMCPSettings() {
        settingsSection = .mcp
        showSettings = true
    }
}

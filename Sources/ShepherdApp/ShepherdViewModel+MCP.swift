import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

@MainActor
extension ShepherdViewModel {
    /// Agents' MCP extensions report each server's state to `mcpReports` and ask for credentials
    /// through `mcpCredentialSource`, which Settings ▸ MCP servers' store (Keychain and OAuth)
    /// provides. Until one is set, a request that needs credentials fails with `mcp_unavailable`,
    /// and servers that need none work regardless.
    func installMCPHandlers() {
        server.onMCPReport = { [weak self] agentID, report in
            MainActor.assumeIsolated {
                guard let self, self.state.agents.contains(where: { $0.id == agentID }) else { return }
                self.mcpReports.apply(report, from: agentID)
            }
        }
        server.onMCPRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let self, let source = self.mcpCredentialSource else {
                    respond(.failure(code: "mcp_unavailable",
                                     message: "Shepherd can't hand over \(request.server)'s credentials yet: check Settings ▸ MCP servers."))
                    return
                }
                Task { @MainActor in respond(await source(request)) }
            }
        }
    }
}

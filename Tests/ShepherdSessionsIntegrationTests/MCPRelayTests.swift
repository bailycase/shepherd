import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The MCP extension's two messages: a credentials request relayed to the app and answered by
/// id, and a fire-and-forget report reaching the app's callback.
@Suite("MCP relay", .integrationTimeLimit)
struct MCPRelayTests {
    @Test func aCredentialsRequestReachesTheHandlerAndItsAnswerKeepsTheID() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agentID = AgentID()
        let seen = Locked<[MCPRequest]>([])
        h.server.onMCPRequest = { request, respond in
            seen.withValue { $0.append(request) }
            if request.server == "notion" {
                respond(.failure(code: MCPFailureCode.needsSignIn, message: "notion needs you to sign in: Settings ▸ MCP servers."))
            } else {
                respond(.credentials(MCPCredentials(bearer: "tok", env: ["DATABASE_URI": "postgres://db"], expiresAtMs: 42)))
            }
        }
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.mcpCredentials(id: 7, agentID: agentID, server: "linear", reason: .unauthorized, challenge: "Bearer scope=\"read\""))
        #expect(try await client.reply()
            == .mcpCredentials(id: 7, credentials: MCPCredentials(bearer: "tok", env: ["DATABASE_URI": "postgres://db"], expiresAtMs: 42)))
        try client.send(.mcpCredentials(id: 8, agentID: agentID, server: "notion", reason: .connect, challenge: nil))
        #expect(try await client.reply()
            == .error(id: 8, code: "needs_sign_in", message: "notion needs you to sign in: Settings ▸ MCP servers."))
        #expect(seen.current == [
            MCPRequest(agentID: agentID, server: "linear", reason: .unauthorized, challenge: "Bearer scope=\"read\""),
            MCPRequest(agentID: agentID, server: "notion", reason: .connect),
        ])
    }

    /// A server without the app (headless, tests) still answers, so the extension never waits.
    @Test func withoutAHandlerTheAnswerIsMCPUnavailable() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.mcpCredentials(id: 3, agentID: AgentID(), server: "grafana", reason: .connect, challenge: nil))
        let reply = try await client.reply()
        guard case .error(3, "mcp_unavailable", _) = reply else {
            Issue.record("expected mcp_unavailable, got \(reply)")
            return
        }
    }

    @Test func aReportReachesTheCallback() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agentID = AgentID()
        let reports = Locked<[MCPServerReport]>([])
        h.server.onMCPReport = { id, report in
            #expect(id == agentID)
            reports.withValue { $0.append(report) }
        }
        let client = try ExtensionClient(path: h.socketPath)
        let report = MCPServerReport(server: "postgres", status: MCPServerStatus(state: .connected), transport: .stdio,
                                     serverName: "postgres-mcp", tools: [MCPToolInfo(name: "query", description: "Run SQL.")])

        try client.send(.mcpReport(agentID: agentID, report: report))
        try await eventually("the report callback") { reports.current == [report] }
    }
}

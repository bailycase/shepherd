import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ MCP servers against a real server: an agent's MCP extension asks for a server's
/// credentials over the extension socket and gets the app's answer back by id, a server with no
/// app answers `mcp_unavailable`, and a state report reaches the app in order.
@Suite("MCP relay", .integrationTimeLimit)
struct MCPRelayTests {
    @Test func aCredentialsRequestIsAnsweredByTheApp() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let asked = Locked<[MCPRequest]>([])
        h.server.onMCPRequest = { request, respond in
            asked.withValue { $0.append(request) }
            switch request.server {
            case "postgres":
                respond(.credentials(MCPCredentials(env: ["DATABASE_URI": "postgres://u:p@db/app"])))
            default:
                respond(.failure(code: "needs_sign_in", message: "\(request.server) needs you to sign in: Settings ▸ MCP servers."))
            }
        }
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.mcpCredentials(id: 1, agentID: worker.agent.id, server: "postgres", reason: .connect, challenge: nil))
        #expect(try await agent.reply() == .mcpCredentials(id: 1, credentials: MCPCredentials(env: ["DATABASE_URI": "postgres://u:p@db/app"])))

        let challenge = #"Bearer resource_metadata="https://mcp.notion.com/.well-known/oauth-protected-resource""#
        try agent.send(.mcpCredentials(id: 2, agentID: worker.agent.id, server: "notion", reason: .unauthorized, challenge: challenge))
        #expect(try await agent.reply() == .error(id: 2, code: "needs_sign_in", message: "notion needs you to sign in: Settings ▸ MCP servers."))
        #expect(asked.current.last == MCPRequest(agentID: worker.agent.id, server: "notion", reason: .unauthorized, challenge: challenge))

        // Only a live agent may ask: the answer can carry secrets.
        try agent.send(.mcpCredentials(id: 3, agentID: AgentID(), server: "postgres", reason: .connect, challenge: nil))
        guard case .error(3, "no_such_agent", _) = try await agent.reply() else { Issue.record("a stranger was answered"); return }
        #expect(asked.current.count == 2)
    }

    @Test func withoutTheAppARequestIsMCPUnavailable() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.mcpCredentials(id: 7, agentID: worker.agent.id, server: "grafana", reason: .connect, challenge: nil))
        guard case .error(7, "mcp_unavailable", let message) = try await agent.reply() else {
            Issue.record("expected mcp_unavailable")
            return
        }
        #expect(message.contains("grafana"))
    }

    @Test func reportsReachTheAppInOrder() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let heard = Locked<[(AgentID, MCPServerReport)]>([])
        h.server.onMCPReport = { agentID, report in heard.withValue { $0.append((agentID, report)) } }
        let agent = try ExtensionClient(path: h.socketPath)

        let starting = MCPServerReport(server: "fake", status: MCPServerStatus(state: .starting))
        let connected = MCPServerReport(server: "fake", status: MCPServerStatus(state: .connected), transport: .stdio,
                                        serverName: "Fake MCP", tools: [MCPToolInfo(name: "echo", description: "Echo.")])
        try agent.send(.mcpReport(agentID: worker.agent.id, report: starting))
        try agent.send(.mcpReport(agentID: AgentID(), report: starting))
        try agent.send(.mcpReport(agentID: worker.agent.id, report: connected))

        try await eventually("both reports") { heard.current.count >= 2 }
        await drainMainQueue()
        #expect(heard.current.map(\.1) == [starting, connected], "a stranger's report is dropped, the rest keep their order")
        #expect(heard.current.allSatisfy { $0.0 == worker.agent.id })
    }
}

import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdApp

/// The live part of a Settings ▸ MCP servers row (CONTRACT §5, steps 3–5): what this Mac's agents
/// report, kept per agent and dropped with the agent.
@MainActor
@Suite("MCP agent reports")
struct MCPAgentReportsTests {
    private let a = AgentID(rawValue: "a")
    private let b = AgentID(rawValue: "b")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func report(_ state: MCPServerStatus.State, tools: [MCPToolInfo]? = nil, message: String? = nil) -> MCPServerReport {
        MCPServerReport(server: "fake", status: MCPServerStatus(state: state, message: message), transport: .stdio,
                        serverName: "Fake MCP", tools: tools)
    }

    @Test(arguments: [
        // (agent a, agent b, error age in seconds) → live state
        (MCPServerStatus.State.connected, MCPServerStatus.State.error, 0.0, MCPServerStatus.State?.some(.connected)),
        (.idle, .error, 60, .error),
        (.idle, .error, 11 * 60, nil),
        (.starting, .idle, 0, .starting),
        (.error, .starting, 60, .error),
        (.idle, .idle, 0, nil),
    ])
    func anyConnectedAgentWinsThenARecentErrorThenStarting(first: MCPServerStatus.State, second: MCPServerStatus.State,
                                                            errorAge: Double, expected: MCPServerStatus.State?) {
        let reports = MCPAgentReports()
        let at = { (state: MCPServerStatus.State) in state == .error ? now.addingTimeInterval(-errorAge) : now }
        reports.apply(report(first), from: a, at: at(first))
        reports.apply(report(second), from: b, at: at(second))
        #expect(reports.liveState(for: "fake", now: now)?.state == expected)
    }

    @Test func aStateReportKeepsTheToolsItsAgentListedAndTheServerKeepsItsLatestList() {
        let reports = MCPAgentReports()
        let tools = [MCPToolInfo(name: "echo", description: "Echo.")]
        reports.apply(report(.connected, tools: tools), from: a, at: now)
        reports.apply(report(.idle), from: a, at: now)
        #expect(reports.byServer["fake"]?[a]?.report.tools == tools)
        #expect(reports.tools["fake"] == tools)
        #expect(reports.connection["fake"] == MCPConnectionInfo(transport: .stdio, serverName: "Fake MCP"))
        #expect(reports.connectedAgents(for: "fake") == 0)
    }

    @Test func reportsFromAgentsThatAreGoneAreDropped() {
        let reports = MCPAgentReports()
        reports.apply(report(.connected), from: a, at: now)
        reports.apply(report(.needsSignIn, message: "fake needs you to sign in"), from: b, at: now)
        #expect(reports.signInState(for: "fake")?.state == .needsSignIn)
        reports.retain(agents: [b])
        #expect(reports.liveState(for: "fake", now: now) == nil)
        reports.retain(agents: [])
        #expect(reports.byServer.isEmpty)
    }
}

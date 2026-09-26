import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

/// How a server was last reached, and what it calls itself (`initialize`'s serverInfo).
struct MCPConnectionInfo: Equatable {
    var transport: MCPTransportKind?
    var serverName: String?
}

/// What this Mac's agents last said about each MCP server (`ExtensionMessage.mcpReport`), for
/// Settings ▸ MCP servers: the live part of a row's status, its transport and server name, and
/// the tools it listed. Reports are kept per agent and dropped when the agent goes. The page adds
/// what only the app knows (a server turned off, its sign-in) on top of `liveState`.
@MainActor @Observable
final class MCPAgentReports {
    struct Entry: Equatable {
        var report: MCPServerReport
        var at: Date
    }

    /// Server name → agent → its last report.
    private(set) var byServer: [String: [AgentID: Entry]] = [:]
    /// Server name → the tools it listed most recently, from any agent.
    private(set) var tools: [String: [MCPToolInfo]] = [:]
    /// Server name → how it was last reached and what it calls itself.
    private(set) var connection: [String: MCPConnectionInfo] = [:]

    /// An error older than this no longer colours the row.
    static let errorWindow: TimeInterval = 10 * 60

    func apply(_ report: MCPServerReport, from agentID: AgentID, at now: Date = Date()) {
        var entry = Entry(report: report, at: now)
        // A state report carries no tools: keep the list this agent sent before.
        if entry.report.tools == nil { entry.report.tools = byServer[report.server]?[agentID]?.report.tools }
        if byServer[report.server]?[agentID] != entry { byServer[report.server, default: [:]][agentID] = entry }
        if let listed = report.tools, tools[report.server] != listed { tools[report.server] = listed }
        if report.transport != nil || report.serverName != nil {
            let next = MCPConnectionInfo(transport: report.transport ?? connection[report.server]?.transport,
                                         serverName: report.serverName ?? connection[report.server]?.serverName)
            if connection[report.server] != next { connection[report.server] = next }
        }
    }

    /// Drops every report from an agent that is gone.
    func retain(agents live: Set<AgentID>) {
        for (server, agents) in byServer where agents.keys.contains(where: { !live.contains($0) }) {
            let kept = agents.filter { live.contains($0.key) }
            if kept.isEmpty { byServer.removeValue(forKey: server) } else { byServer[server] = kept }
        }
    }

    /// Steps 3–5 of a row's status (CONTRACT §5): any agent connected → connected; an error within
    /// the last ten minutes → error; any agent starting → starting; otherwise nil (idle). Sign-in
    /// states come from the app's own OAuth state, which outranks these.
    func liveState(for server: String, now: Date = Date()) -> MCPServerStatus? {
        let entries = byServer[server]?.values.map { $0 } ?? []
        if let connected = entries.first(where: { $0.report.status.state == .connected }) { return connected.report.status }
        let recentErrors = entries.filter { $0.report.status.state == .error && now.timeIntervalSince($0.at) < Self.errorWindow }
        if let error = recentErrors.max(by: { $0.at < $1.at }) { return error.report.status }
        if let starting = entries.first(where: { $0.report.status.state == .starting }) { return starting.report.status }
        return nil
    }

    /// The agents' latest sign-in state for a server (needsSignIn, expired, needsScopes), if any.
    func signInState(for server: String) -> MCPServerStatus? {
        let signIn: Set<MCPServerStatus.State> = [.needsSignIn, .expired, .needsScopes]
        return byServer[server]?.values.filter { signIn.contains($0.report.status.state) }.max(by: { $0.at < $1.at })?.report.status
    }

    /// How many live agents have the server connected.
    func connectedAgents(for server: String) -> Int {
        byServer[server]?.values.filter { $0.report.status.state == .connected }.count ?? 0
    }
}

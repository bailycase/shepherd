import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

/// Settings ▸ MCP servers as SettingsMCP draws it: the seven board servers in every row state, from
/// a scratch mcp.json and secrets in memory, with what `pi mcp list --json` printed for them handed
/// to the real store (the page reads nothing else), and no network or pi.
@MainActor
enum MCPPreviewFixtures {
    /// `pi mcp list --json` for the board: linear connected, sentry and notion waiting for a sign-in,
    /// github and postgres connected, playwright not connected, grafana failed to start.
    private struct BoardCLI: MCPCLI {
        func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval,
                 onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult {
            func names(_ first: [String], total: Int) -> [String] { first + (first.count..<total).map { "tool_\($0 + 1)" } }
            let servers: [[String: Any]] = [
                ["name": "linear", "state": "connected", "tools": names(["list_issues", "create_issue", "update_issue", "get_issue"], total: 21)],
                ["name": "sentry", "state": "needs-auth", "tools": [String]()],
                ["name": "notion", "state": "needs-auth", "tools": [String]()],
                ["name": "github", "state": "connected", "tools": names(["search_code"], total: 41)],
                ["name": "postgres", "state": "connected", "tools": names(["query", "list_schemas"], total: 9)],
                ["name": "playwright", "state": "disconnected", "tools": [String]()],
                ["name": "grafana", "state": "failed", "tools": [String](), "error": "spawn mcp-grafana ENOENT"],
            ].map { var server = $0; server["enabled"] = true; server["exposure"] = "deferred"; server["transport"] = "x"; server["scope"] = "global"; return server }
            let data = (try? JSONSerialization.data(withJSONObject: ["servers": servers, "errors": [String]()])) ?? Data()
            return MCPCLIResult(status: 1, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
    }

    /// The edges: a server set to Direct with chosen tools, one pi can't run (legacy SSE), a long name and a long error, and one switched off.
    static let edgeConfig = """
    { "mcpServers": {
      "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": { "Authorization": "Bearer ${keychain:github/Authorization}" },
                  "shepherd": { "exposure": "direct", "tools": ["search_code", "get_file_contents", "list_pull_requests"] } },
      "legacy-events": { "type": "sse", "url": "https://events.example.com/sse" },
      "a-server-with-a-name-long-enough-to-need-truncating-somewhere-near-the-edge": { "command": "uvx", "args": ["some-quite-long-package-name", "--with-many-flags", "--and-more=1"] },
      "slow": { "command": "node", "args": ["slow.js"] },
      "quiet": { "command": "quiet", "shepherd": { "enabled": false } }
    }}
    """

    private struct EdgeCLI: MCPCLI {
        func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval,
                 onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult {
            let servers: [[String: Any]] = [
                ["name": "github", "state": "connected", "tools": ["search_code", "get_file_contents", "list_pull_requests", "create_issue", "get_issue", "list_issues"]],
                ["name": "a-server-with-a-name-long-enough-to-need-truncating-somewhere-near-the-edge", "state": "failed", "tools": [String](),
                 "error": "MCP error -32000: Connection closed because the server printed an unusually long message about what it could not find on this machine"],
                ["name": "slow", "state": "connected", "tools": ["wait"]],
                ["name": "quiet", "state": "disabled", "tools": [String]()],
            ].map { var server = $0; server["enabled"] = server["state"] as? String != "disabled"; server["exposure"] = "deferred"; server["transport"] = "x"; server["scope"] = "global"; return server }
            let data = (try? JSONSerialization.data(withJSONObject: ["servers": servers, "errors": [String]()])) ?? Data()
            return MCPCLIResult(status: 1, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
    }

    /// The edges above, after the page asked pi once.
    static func edgeStore() async throws -> MCPStore {
        let directory = try makeScratchDirectory()
        let config = directory.appendingPathComponent("mcp.json")
        try Data(edgeConfig.utf8).write(to: config)
        let store = MCPStore(dependencies: dependencies(config: config, secrets: InMemorySecretStore(["secret/github/Authorization": "t"]), cli: EdgeCLI()))
        store.refresh()
        await store.settle()
        return store
    }

    private struct NoHTTP: MCPHTTP {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func dependencies(config: URL, secrets: InMemorySecretStore, cli: MCPCLI, auth: Data? = nil) -> MCPStore.Dependencies {
        MCPStore.Dependencies(file: MCPConfigFile(url: config), secrets: secrets, http: NoHTTP(), cli: cli, preparePi: { nil },
                              authData: { auth }, openURL: { _ in }, copy: { _ in }, now: { now })
    }

    /// An empty store on a scratch file, for the sheets.
    static func emptyStore() throws -> MCPStore {
        let directory = try makeScratchDirectory()
        return MCPStore(dependencies: dependencies(config: directory.appendingPathComponent("mcp.json"), secrets: InMemorySecretStore(), cli: BoardCLI()))
    }

    /// The board, after the page asked pi once: linear is signed in, and the rest are as `BoardCLI` says.
    static func boardStore() async throws -> MCPStore {
        let directory = try makeScratchDirectory()
        let config = directory.appendingPathComponent("mcp.json")
        try Data(MCPBoardConfig.json.utf8).write(to: config)
        let secrets = InMemorySecretStore([
            "secret/postgres/DATABASE_URI": "postgres://db",
            "secret/grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa",
        ])
        let auth = Data(#"{"mcp__linear|https://mcp.linear.app/mcp": {"serverUrl": "https://mcp.linear.app/mcp"}}"#.utf8)
        let store = MCPStore(dependencies: dependencies(config: config, secrets: secrets, cli: BoardCLI(), auth: auth))
        store.refresh()
        await store.settle()
        return store
    }
}

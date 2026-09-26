import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

/// Settings ▸ MCP servers as SettingsMCP draws it: the seven board servers in every row state,
/// from a scratch mcp.json, secrets in memory, and no network or node.
@MainActor
enum MCPPreviewFixtures {
    private struct NoProbe: MCPProbeRunner {
        func run(input: Data, timeout: TimeInterval) async -> Data { Data() }
    }

    /// A token endpoint that turns every refresh down, so sentry reads Expired.
    private struct RefusingTokens: MCPHTTP {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"error":"invalid_grant"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: [:])!)
        }
    }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func tools(_ first: [String], total: Int) -> [MCPToolInfo] {
        let names = first + (first.count..<total).map { "tool_\($0 + 1)" }
        return names.map {
            MCPToolInfo(name: $0, description: "Does \($0.replacingOccurrences(of: "_", with: " ")) with the service’s API.",
                        inputSchema: .object(["type": .string("object"), "properties": .object(["id": .object(["type": .string("string")])])]))
        }
    }

    private static func token(scopes: [String], expiresIn: Int64 = 3_600_000) -> String {
        let nowMs = MCPStore.ms(now)
        let token = MCPOAuthToken(issuer: "https://auth", tokenEndpoint: "https://auth/token", clientID: "c",
                                  redirectURI: "http://127.0.0.1:1/callback", resource: "https://mcp", accessToken: "a",
                                  refreshToken: "r", expiresAtMs: nowMs + expiresIn, scopes: scopes, account: "baily@acme.dev",
                                  refreshedAtMs: nowMs - 2 * 3_600_000)
        return String(decoding: (try? JSONEncoder().encode(token)) ?? Data(), as: UTF8.self)
    }

    /// An empty store on a scratch file, for the sheets.
    static func emptyStore() throws -> MCPStore {
        let directory = try makeScratchDirectory()
        return MCPStore(dependencies: .init(
            file: MCPConfigFile(url: directory.appendingPathComponent("mcp.json")), cacheURL: directory.appendingPathComponent("tools.json"),
            secrets: InMemorySecretStore(), http: RefusingTokens(), probe: MCPProbe(runner: NoProbe()),
            openURL: { _ in }, copy: { _ in }, now: { now }))
    }

    /// The board: linear connected, sentry expired, notion waiting for a sign-in, github idle,
    /// postgres connected, playwright idle, grafana failed.
    static func boardStore() async throws -> MCPStore {
        let directory = try makeScratchDirectory()
        let config = directory.appendingPathComponent("mcp.json")
        try Data(MCPBoardConfig.json.utf8).write(to: config)
        let secrets = InMemorySecretStore([
            "oauth/linear": token(scopes: ["read", "write", "issues:create"]),
            "oauth/sentry": token(scopes: ["read"]),
            "secret/postgres/DATABASE_URI": "postgres://db",
            "secret/grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa",
        ])
        let store = MCPStore(dependencies: .init(
            file: MCPConfigFile(url: config), cacheURL: directory.appendingPathComponent("tools.json"), secrets: secrets,
            http: RefusingTokens(), probe: MCPProbe(runner: NoProbe()), openURL: { _ in }, copy: { _ in }, now: { now }))
        let counts: [String: ([String], Int)] = [
            "linear": (["list_issues", "create_issue", "update_issue", "get_issue"], 21), "sentry": (["search_issues"], 16),
            "github": (["search_code"], 41), "postgres": (["query", "list_schemas"], 9), "playwright": (["browser_navigate"], 22),
            "grafana": (["query_prometheus"], 34),
        ]
        for (name, (first, total)) in counts {
            guard let entry = store.entry(name) else { continue }
            store.finishProbe(name, entry: entry,
                              result: .connected(transport: entry.transport, serverName: name, tools: tools(first, total: total)))
        }
        let notion = try #require(store.entry("notion"))
        store.finishProbe("notion", entry: notion, result: .failed(MCPServerStatus(state: .needsSignIn), challenge: nil))
        _ = await store.credentials(for: MCPRequest(agentID: AgentID(), server: "sentry", reason: .unauthorized))
        return store
    }

    /// What a live agent reports: linear and postgres connected, grafana failed to start.
    static func report(to store: MCPStore, from agent: AgentID) {
        store.receive(MCPServerReport(server: "linear", status: MCPServerStatus(state: .connected), transport: .streamableHTTP), from: agent)
        store.receive(MCPServerReport(server: "postgres", status: MCPServerStatus(state: .connected), transport: .stdio), from: agent)
        store.receive(MCPServerReport(server: "grafana", status: MCPServerStatus(
            state: .error, message: "Couldn’t start: mcp-grafana isn’t installed")), from: agent)
    }
}

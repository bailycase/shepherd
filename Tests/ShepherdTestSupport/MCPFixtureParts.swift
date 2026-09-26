import Foundation

/// The contract's seven board servers, as ~/.config/mcp/mcp.json holds them.
public enum MCPBoardConfig {
    public static let json = """
    { "mcpServers": {
      "linear":  { "type": "http", "url": "https://mcp.linear.app/mcp", "shepherd": { "start": "whenUsed", "exposure": "proxy" } },
      "sentry":  { "type": "http", "url": "https://mcp.sentry.dev/mcp" },
      "notion":  { "type": "http", "url": "https://mcp.notion.com/mcp", "shepherd": { "start": "whenUsed" } },
      "github":  { "type": "http", "url": "https://api.githubcopilot.com/mcp/",
                   "headers": { "Authorization": "Bearer ${GITHUB_TOKEN}" } },
      "postgres": { "command": "uvx", "args": ["postgres-mcp", "--access-mode=restricted"],
                    "env": { "DATABASE_URI": "${keychain:postgres/DATABASE_URI}" } },
      "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] },
      "grafana": { "command": "mcp-grafana", "args": ["--disable-write"],
                   "env": { "GRAFANA_URL": "https://grafana.acme.internal",
                            "GRAFANA_SERVICE_ACCOUNT_TOKEN": "${keychain:grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN}" },
                   "shepherd": { "start": "whenUsed", "idleMinutes": 10 } }
    }}
    """
}

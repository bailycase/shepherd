import SwiftUI

// MCPStates: every row state, a row's detail, the budget, and the sign-in sheet's three states.

private let rows: [MCPServerRowModel] = [
    .init(name: "postgres", kind: .local, endpoint: "uvx postgres-mcp --access-mode=restricted", status: .connected,
          signIn: .secret("DATABASE_URI"), tools: 9),
    .init(name: "github", kind: .remote, endpoint: "https://api.githubcopilot.com/mcp/", status: .starting,
          note: .starting("Starting on This Mac…"), signIn: .variable("$GITHUB_TOKEN"), tools: 41),
    .init(name: "playwright", kind: .local, endpoint: "npx @playwright/mcp@latest", status: .idle, signIn: .none, tools: 22),
    .init(name: "notion", kind: .remote, endpoint: "https://mcp.notion.com/mcp", status: .needsYou, signIn: .signIn, tools: nil),
    .init(name: "sentry", kind: .remote, endpoint: "https://mcp.sentry.dev/mcp", status: .needsYou, signIn: .expired, tools: 16),
    .init(name: "linear", kind: .remote, endpoint: "https://mcp.linear.app/mcp", status: .needsYou,
          signIn: .moreAccess(["issues:write"]), tools: 21),
    .init(name: "grafana", kind: .local, endpoint: "mcp-grafana --disable-write", status: .error,
          note: .error("Couldn’t start: mcp-grafana isn’t installed"), signIn: .variables(2), tools: 34),
    .init(name: "stripe", kind: .remote, endpoint: "https://mcp.stripe.com", status: .off, signIn: .account("baily@acme.dev"),
          tools: 18, enabled: false),
]

private let noActions = MCPServerRow.Actions(toggle: { _ in }, open: {}, signIn: {})

private let linearDetail = MCPServerDetailModel(
    signIn: .signedIn(account: "baily@acme.dev", scopes: ["read", "write", "issues:create"], note: "OAuth · refreshed 2h ago"),
    toolNames: ["list_issues", "create_issue", "update_issue", "get_issue", "list_teams"], toolCount: 21, direct: false,
    proxyCost: "~200 tok", directCost: "~3,900 tok", transport: "Streamable HTTP",
    startOptions: ["When used", "With each session", "Always on"], start: 0,
    hosts: [.init(name: "This Mac", detail: "connected", mark: .done)])

private let signInSteps: [MCPSignInSheetModel.Step] = [
    .init(id: "found", title: "Found Notion’s sign-in server", note: "mcp.notion.com pointed the way", state: .done),
    .init(id: "registered", title: "Registered Shepherd with Notion", note: "Dynamic client registration", state: .done),
    .init(id: "browser", title: "Waiting for you in the browser", note: "Approve access on notion.com; this closes by itself.", state: .live),
]

#Preview("MCP server rows") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            MCPServerListHeader()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                MCPServerRow(row, open: false, first: index == 0, actions: noActions)
            }
        }
        .frame(width: 820)
    }
}

#Preview("MCP server detail") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            MCPServerRow(rows[5], open: true, first: true, actions: noActions)
            MCPServerDetail(linearDetail, actions: .none)
        }
        .frame(width: 820)
    }
}

#Preview("MCP budget and status dots") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            MCPBudget(tokens: "~200 tokens", fraction: 0.03,
                      note: "One mcp tool finds and calls any of the 143 tools. Servers set to “Each tool” add their tools here.")
                .frame(width: 280)
            HStack(spacing: NW.Space.l) {
                ForEach(MCPDotState.allCases, id: \.self) { MCPStatusDot($0) }
            }
        }
    }
}

#Preview("MCP sign-in sheet") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            MCPSignInSheet(.init(title: "Sign in to Notion", subtitle: "Finish signing in on notion.com.", steps: signInSteps,
                                 phase: .waiting), actions: .none)
            MCPSignInSheet(.init(title: "Sign in to Notion", subtitle: "notion is connected: 14 tools.",
                                 steps: signInSteps.map { var step = $0; step.state = .done; return step }, phase: .done), actions: .none)
            MCPSignInSheet(.init(title: "Sign in to Notion", subtitle: "Nothing was saved.",
                                 steps: Array(signInSteps.prefix(2)) + [.init(id: "browser", title: "Notion didn’t allow access",
                                                                              note: "access_denied: you chose Cancel on notion.com.",
                                                                              state: .failed)],
                                 phase: .failed, details: "denied(error: \"access_denied\")"), actions: .none)
        }
    }
}

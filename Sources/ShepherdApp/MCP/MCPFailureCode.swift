/// The error codes an MCP credentials request fails with (`MCPOutcome.failure`). The MCP
/// extension reads them to pick the state it reports.
enum MCPFailureCode {
    static let needsSignIn = "needs_sign_in"
    static let expired = "expired"
    static let needsScopes = "needs_scopes"
    static let missingSecret = "missing_secret"
    static let noSuchServer = "no_such_server"
    static let unavailable = "mcp_unavailable"
}

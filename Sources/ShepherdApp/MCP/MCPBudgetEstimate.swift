import Foundation

/// What an MCP server costs in every prompt. pi lists only each tool's name, so these are
/// measured figures per server, not a sum over the tools' schemas: a server that is searched adds
/// a line to the system prompt, and a server set to Direct declares each of its tools.
enum MCPBudgetEstimate {
    /// A searched server's line in the system prompt's `mcp_servers` section.
    static let searchServerTokens = 15
    /// One declared tool, its name, description and schema: 211 tokens on the stand-in catalog the
    /// tests measure (845 characters), and real servers' tools run larger or smaller.
    static let directToolTokens = 200

    static func directTokens(count: Int) -> Int { count * directToolTokens }

    static func visible(_ tools: [String], chosen: [String]?) -> [String] {
        guard let chosen else { return tools }
        let set = Set(chosen)
        return tools.filter { set.contains($0) }
    }

    /// Under 1,000 to the nearest 10, above it to the nearest 100.
    static func rounded(_ tokens: Int) -> Int {
        let step = tokens < 1000 ? 10 : 100
        return Int((Double(tokens) / Double(step)).rounded()) * step
    }

    /// "~3,900 tok"
    static func shortLabel(_ tokens: Int) -> String {
        "~\(rounded(tokens).formatted(.number.grouping(.automatic))) tok"
    }
}

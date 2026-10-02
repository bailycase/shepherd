import Foundation

/// What MCP servers cost in every prompt (docs/mcp.md › What a prompt costs). pi lists only each
/// tool's name, so these are measured figures per server, not a sum over the tools' schemas:
/// a server that is searched adds a line to the system prompt (and the first of them pulls in the
/// `tool_search` declaration), and a server set to Direct declares each of its tools.
enum MCPBudgetEstimate {
    struct Server: Equatable {
        var name: String
        var direct: Bool
        /// Its tools the agent may use: all of them, or the ones chosen.
        var toolCount: Int
    }

    /// `tool_search`'s declaration and the `mcp_servers` section's frame: 889 characters over a
    /// prompt with no MCP, with one server, on pi 1.0.
    static let searchBaseTokens = 200
    /// One searched server's line in that section.
    static let searchServerTokens = 15
    /// One declared tool, its name, description and schema: 211 tokens on the stand-in catalog the
    /// tests measure (845 characters), and real servers' tools run larger or smaller.
    static let directToolTokens = 200

    static func directTokens(count: Int) -> Int { count * directToolTokens }

    /// The tokens every prompt carries, and a line saying why.
    static func estimate(_ servers: [Server]) -> (tokens: Int, note: String) {
        guard !servers.isEmpty else {
            return (0, "No servers yet. A server you add costs almost nothing until the agent needs it.")
        }
        let searched = servers.filter { !$0.direct }
        let direct = servers.filter(\.direct)
        let search = searched.isEmpty ? 0 : searchBaseTokens + searched.count * searchServerTokens
        let declared = direct.reduce(0) { $0 + directTokens(count: $1.toolCount) }
        let note: String
        if direct.isEmpty {
            note = "Tools stay out of the prompt until the agent searches for one; a search then adds the best eight for the rest of the thread."
        } else {
            let names = direct.map(\.name).formatted(.list(type: .and))
            let tools = direct.reduce(0) { $0 + $1.toolCount }
            note = "\(names) \(direct.count == 1 ? "is" : "are") set to Direct, which declares \(tools) tool\(tools == 1 ? "" : "s") in every prompt."
                + (searched.isEmpty ? "" : " The rest are searched.")
        }
        return (search + declared, note)
    }

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

    /// "~200 tokens"
    static func longLabel(_ tokens: Int) -> String {
        "~\(rounded(tokens).formatted(.number.grouping(.automatic))) tokens"
    }
}

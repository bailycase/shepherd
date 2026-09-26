import Foundation
import ShepherdProtocol

/// What MCP servers cost in every prompt. Through the one `mcp` tool, all of them together cost
/// about 200 tokens; a server set to "Each tool on its own" adds each tool's name, description
/// and schema, at about four bytes a token.
enum MCPBudgetEstimate {
    static let proxyTokens = 200

    static func tokens(for tool: MCPToolInfo) -> Int {
        let schema = (try? Self.encoder.encode(tool.inputSchema)).map { $0.count } ?? 2
        let bytes = tool.name.utf8.count + tool.description.utf8.count + schema
        return (bytes + 3) / 4 + 10
    }

    /// The server's tools on their own, limited to the chosen ones.
    static func directTokens(_ tools: [MCPToolInfo], chosen: [String]?) -> Int {
        visible(tools, chosen: chosen).reduce(0) { $0 + tokens(for: $1) }
    }

    /// The whole prompt: 200 when any server goes through the one tool, plus every direct tool.
    static func total(_ servers: [(exposure: MCPExposure, tools: [MCPToolInfo], chosen: [String]?)]) -> Int {
        let proxy = servers.contains { $0.exposure == .proxy } ? proxyTokens : 0
        return servers.filter { $0.exposure == .direct }.reduce(proxy) { $0 + directTokens($1.tools, chosen: $1.chosen) }
    }

    static func visible(_ tools: [MCPToolInfo], chosen: [String]?) -> [MCPToolInfo] {
        guard let chosen else { return tools }
        let set = Set(chosen)
        return tools.filter { set.contains($0.name) }
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

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

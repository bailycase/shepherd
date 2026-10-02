import Foundation

/// How a call on pi's MCP reads as an activity line (docs/mcp.md › In the thread): a server's
/// tool, named as pi names it (`mcp__github__search_issues`), reads "Called search_issues" with
/// the server and what it was asked in the line's meta ("github · “label:bug”"); the search that
/// loads deferred tools is the quiet "Searched tools" with what was searched. Names are pi's
/// (characters outside letters, digits and `_` are already `_`). Shared with the iOS client,
/// which draws the same lines.
public enum NativeMCPActivity {
    public static let searchTool = "tool_search"
    static let prefix = "mcp__"

    /// `mcp__github__search_issues` is the server "github" and the tool "search_issues"; nil for any other name.
    public static func parts(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let gap = rest.range(of: "__"), gap.lowerBound != rest.startIndex, gap.upperBound != rest.endIndex else { return nil }
        return (String(rest[..<gap.lowerBound]), String(rest[gap.upperBound...]))
    }

    public static func isMCPTool(_ name: String) -> Bool { parts(name) != nil }

    /// The first of these arguments a call has: what an MCP tool was asked, which is the line's
    /// only other word. A tool's schema is its server's, so there is no more to know.
    static let subjectKeys = ["query", "q", "url", "path", "pattern", "name", "title", "text", "command"]

    /// "8" from `Loaded 8 tools. They are available from your next call:`; nil when the result says no count.
    public static func loadedCount(fromResult output: String) -> Int? {
        guard let first = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
              first.hasPrefix("Loaded "), let count = first.dropFirst("Loaded ".count).split(separator: " ").first else { return nil }
        return Int(count)
    }

    /// The line while the call runs; nil for a call that is neither.
    static func running(_ name: String, tool: String) -> String? {
        if name == searchTool { return "Searching tools" }
        return isMCPTool(name) ? "Calling \(tool)" : nil
    }

    static func failed(_ name: String, tool: String) -> String? {
        if name == searchTool { return "Tool search failed" }
        return isMCPTool(name) ? "\(tool) failed" : nil
    }

    static func stopped(_ name: String, tool: String) -> String? {
        if name == searchTool { return "Tool search stopped" }
        return isMCPTool(name) ? "\(tool) stopped" : nil
    }

    /// The finished line of calls that share one tool, and its meta; nil for a call that is neither.
    static func done(_ calls: [NativeActivityCall], duration: String?) -> (String, [String])? {
        let first = calls[0]
        if first.name == searchTool {
            var seen: [String] = []
            for detail in calls.map(\.detail) where !detail.isEmpty && !seen.contains(detail) { seen.append(detail) }
            return ("Searched tools", [seen.joined(separator: " · ")] + [duration].compactMap { $0 })
        }
        guard let parts = parts(first.name) else { return nil }
        if calls.count == 1 { return ("Called \(first.label)", [first.detail] + [duration].compactMap { $0 }) }
        return ("Called \(first.label) \(calls.count) times", [parts.server] + [duration].compactMap { $0 })
    }
}

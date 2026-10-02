import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Calls on pi's MCP as activity lines (docs/mcp.md › In the thread): a server's tool with its
/// server and what it was asked, and the search that loads deferred tools as a quiet line.
@Suite("MCP activity lines")
struct MCPActivityTests {
    typealias F = Fixture

    private static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func call(_ name: String, _ args: [String: Any] = [:], output: String = "", error: Bool = false, status: String = "complete",
                      id: String = UUID().uuidString, start: Double? = nil, end: Double? = nil) -> NativeActivityCall {
        NativeActivityCall(F.tool(name, args: Self.json(args), output: output, error: error, status: status, id: "e-\(id)", callID: id,
                                  startedAt: start, timestamp: end))
    }

    @Test(arguments: [
        ("mcp__github__search_issues", "github", "search_issues"),
        ("mcp__fake__echo", "fake", "echo"),
        ("mcp__my_server__get__thing", "my_server", "get__thing"),
    ])
    func aToolNameSplitsIntoItsServerAndTool(name: String, server: String, tool: String) throws {
        let parts = try #require(NativeMCPActivity.parts(name))
        #expect(parts.server == server && parts.tool == tool)
    }

    @Test(arguments: ["bash", "mcp", "mcp__", "mcp__github", "mcp__github__", "mcp____tool", "tool_search", "list_mcp_resources", "xmcp__a__b"])
    func aNameThatIsNotAServersToolIsNotOne(name: String) {
        #expect(NativeMCPActivity.parts(name) == nil && !NativeMCPActivity.isMCPTool(name))
    }

    @Test func aFinishedCallNamesItsToolItsServerAndWhatItWasAsked() {
        let c = call("mcp__github__search_issues", ["query": "label:bug is:open", "limit": 5], output: "3 results")
        #expect(c.kind == .other && c.label == "search_issues" && c.detail == "github · label:bug is:open")
        let burst = nativeActivityBurst([c])
        #expect(burst.label == "Called search_issues" && burst.meta == "github · label:bug is:open" && burst.state == .done)
        #expect(burst.accessibilityLabel == "Called search_issues, github · label:bug is:open, done")
    }

    @Test(arguments: [
        (["query": "x"], "github · x"),
        (["q": "x"], "github · x"),
        (["url": "https://a.test/b"], "github · https://a.test/b"),
        (["query": "first line\nsecond"], "github · first line"),
        (["query": "wins", "text": "loses"], "github · wins"),
        (["limit": "5"], "github"),
        ([:], "github"),
    ] as [([String: String], String)])
    func theLineSaysWhatTheCallWasAskedFromTheFirstArgumentItKnows(args: [String: String], detail: String) {
        #expect(call("mcp__github__get", args).detail == detail)
    }

    @Test func aRunningCallIsTheLiveLineWithItsServer() {
        let burst = nativeActivityBurst([call("mcp__github__search_issues", ["query": "bug"], status: "running")])
        #expect(burst.state == .running && burst.label == "Calling search_issues" && burst.meta == "github · bug")
    }

    @Test func aFailedCallStaysItsOwnLineWithPisReason() {
        let a = call("mcp__github__search_issues", ["query": "bug"], output: "Tool mcp__github__search_issues not found", error: true)
        let b = call("mcp__github__search_issues", ["query": "bug"], output: "ok")
        let lines = nativeActivityBursts([b, a, b])
        #expect(lines.map(\.state) == [.done, .failed, .done])
        #expect(lines[1].label == "search_issues failed")
        #expect(lines[1].meta == "github · bug · Tool mcp__github__search_issues not found")
    }

    @Test func aStoppedCallSaysSo() {
        let burst = nativeActivityBurst([call("mcp__github__search_issues", ["query": "bug"], error: true, status: "aborted")])
        #expect(burst.label == "search_issues stopped" && burst.meta == "github · bug · stopped")
    }

    @Test func consecutiveCallsOfOneToolMergeAndDifferentToolsDoNot() {
        let search = { call("mcp__github__search_issues", ["query": "bug"], output: "ok") }
        let get = call("mcp__github__get_issue", ["id": "1"], output: "ok")
        let lines = nativeActivityBursts([search(), search(), get, call("mcp__linear__get_issue", [:], output: "ok")])
        #expect(lines.map(\.label) == ["Called search_issues 2 times", "Called get_issue", "Called get_issue"])
        #expect(lines[0].meta == "github")
        #expect(lines.map(\.calls.count) == [2, 1, 1], "another server's tool of the same name is another line")
    }

    @Test func theSearchThatLoadsToolsIsOneQuietLineWithWhatWasSearched() {
        let result = "Loaded 8 tools. They are available from your next call:\n- mcp__fake__echo: Echo the text back."
        let c = call("tool_search", ["query": "echo the text back"], output: result)
        #expect(c.kind == .other && c.detail == "“echo the text back”" && c.stat == "8 loaded")
        let burst = nativeActivityBurst([c])
        #expect(burst.label == "Searched tools" && burst.meta == "“echo the text back”")
        #expect(nativeActivityBurst([call("tool_search", ["query": "x"], status: "running")]).label == "Searching tools")
        #expect(nativeActivityBurst([call("tool_search", ["query": "x"], output: "nope", error: true)]).label == "Tool search failed")
        #expect(nativeActivityBurst([call("tool_search", ["query": "x"], error: true, status: "aborted")]).label == "Tool search stopped")
    }

    @Test func severalSearchesInARowJoinAndListEachQueryOnce() {
        let search = { (query: String) in self.call("tool_search", ["query": query], output: "Loaded 3 tools. They are available from your next call:") }
        let lines = nativeActivityBursts([search("issues"), search("issues"), search("pull requests")])
        #expect(lines.count == 1)
        #expect(lines[0].label == "Searched tools" && lines[0].meta == "“issues” · “pull requests”")
    }

    @Test(arguments: [
        ("Loaded 8 tools. They are available from your next call:\n- a", 8 as Int?),
        ("Loaded 1 tool.", 1),
        ("No tools matched.", nil),
        ("", nil),
        ("Loaded many tools.", nil),
    ])
    func theSearchResultsCountIsReadFromItsFirstLine(output: String, count: Int?) {
        #expect(NativeMCPActivity.loadedCount(fromResult: output) == count)
    }
}

import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// Which commands the slash menu lists: pi's `get_commands`, less the ones no thread can run.
@Suite("Slash menu commands on the host")
struct CommandMenuTests {
    @Test func piBuiltInsThatOnlyWorkInItsTerminalAreLeftOut() throws {
        let value: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"name":"llama","description":"Manage llama.cpp router models","source":"extension",
          "sourceInfo":{"path":"<inline:llama.cpp>","source":"inline","scope":"temporary","origin":"top-level"}},
         {"name":"llama","description":"Mine","source":"extension","sourceInfo":{"path":"/me/llama.ts","source":"local"}},
         {"name":"subagents","source":"extension","sourceInfo":{"path":"/x/shepherd-children.ts"}}]
        """#.utf8))
        #expect(RPCThreadState.projectCommands(value).map(\.description) == ["Mine", nil])
    }

    @Test func theHostsOwnRetryIsLeftOut() throws {
        let value: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"name":"shepherd-retry","source":"extension"},{"name":"session-name","source":"extension"}]
        """#.utf8))
        #expect(RPCThreadState.projectCommands(value).map(\.name) == ["session-name"])
    }
}

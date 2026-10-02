import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// Which commands the slash menu lists: pi's `get_commands`, less the ones no thread can run.
@Suite("Slash menu commands on the host")
struct CommandMenuTests {
    /// pi 1.0 lists its built-in extensions' files as `builtin:<name>`; 0.87.1 listed `<inline:…>`,
    /// which a host on an older engine still reports. The user's own `/llama` stays either way.
    @Test(arguments: [
        #"{"path":"builtin:llama.cpp","source":"builtin","scope":"temporary","origin":"top-level"}"#,
        #"{"path":"<inline:llama.cpp>","source":"inline","scope":"temporary","origin":"top-level"}"#,
    ])
    func piBuiltInsThatOnlyWorkInItsTerminalAreLeftOut(_ builtIn: String) throws {
        let value: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"name":"llama","description":"Manage llama.cpp router models","source":"extension","sourceInfo":\#(builtIn)},
         {"name":"llama","description":"Mine","source":"extension","sourceInfo":{"path":"/me/llama.ts","source":"local"}},
         {"name":"subagents","source":"extension","sourceInfo":{"path":"/x/shepherd-children.ts"}}]
        """#.utf8))
        #expect(RPCThreadState.projectCommands(value).map(\.description) == ["Mine", nil])
    }

    /// pi's own `/mcp` (built-in MCP, which Shepherd's pi turns off: `PiHome.disabledBuiltIns`) is
    /// listed as pi lists it when someone turns it on: it works in RPC mode, answering with the
    /// servers' state, so the menu keeps it.
    @Test func piBuiltInMCPCommandIsKeptWhenSomeoneTurnsItOn() throws {
        let value: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"name":"mcp","description":"Manage MCP servers: sign in, reconnect, enable or disable, and change exposure","source":"extension",
          "sourceInfo":{"path":"builtin:mcp","source":"builtin","scope":"temporary","origin":"top-level"}}]
        """#.utf8))
        #expect(RPCThreadState.projectCommands(value).map(\.name) == ["mcp"])
    }

    @Test func theHostsOwnRetryIsLeftOut() throws {
        let value: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"name":"shepherd-retry","source":"extension"},{"name":"session-name","source":"extension"}]
        """#.utf8))
        #expect(RPCThreadState.projectCommands(value).map(\.name) == ["session-name"])
    }
}

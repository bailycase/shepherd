import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdApp

/// ~/.config/mcp/mcp.json: read tolerantly, written atomically, and every key Shepherd doesn't
/// own kept as it was.
@Suite("MCP config file")
struct MCPConfigFileTests {
    private func scratchFile(_ text: String? = nil) throws -> MCPConfigFile {
        let url = try makeScratchDirectory().appendingPathComponent("mcp.json")
        if let text { try Data(text.utf8).write(to: url) }
        return MCPConfigFile(url: url)
    }

    private func text(_ file: MCPConfigFile) throws -> String {
        try String(contentsOf: file.url, encoding: .utf8)
    }

    static let othersFile = """
    {
      "$schema": "https://example.com/mcp.schema.json",
      "inputs": [{"id": "token", "type": "promptString"}],
      "mcpServers": {
        "linear": {"type": "http", "url": "https://mcp.linear.app/mcp", "disabled": false,
                   "shepherd": {"start": "whenUsed", "note": "kept"}},
        "cursor-only": {"command": "npx", "args": ["-y", "thing"], "env": {"API_KEY": "plaintext-by-cursor"}}
      }
    }
    """

    @Test func anEditKeepsEveryKeyShepherdDoesNotOwn() throws {
        let file = try scratchFile(Self.othersFile)
        try file.update { document in
            var entry = try #require(document.server("linear"))
            var settings = entry.settings
            settings.enabled = false
            entry.settings = settings
            document.upsert(entry)
        }
        guard case .document(let document) = file.read() else { Issue.record("unreadable"); return }
        #expect(document.root["$schema"] == .string("https://example.com/mcp.schema.json"))
        #expect(document.root["inputs"] == .array([.object(["id": .string("token"), "type": .string("promptString")])]))
        let linear = try #require(document.server("linear"))
        #expect(linear.json["disabled"] == .bool(false))
        #expect(linear.json["shepherd"]?["note"] == .string("kept"))
        #expect(linear.json["shepherd"]?["enabled"] == .bool(false))
        #expect(linear.settings.start == .whenUsed)
        // Another tool's entry and its plaintext value stay exactly as written.
        let other = try #require(document.server("cursor-only"))
        #expect(other.env == ["API_KEY": "plaintext-by-cursor"])
        #expect(other.args == ["-y", "thing"])
    }

    @Test func itWritesSortedKeysTwoSpacesAndUnescapedSlashes() throws {
        let file = try scratchFile()
        try file.update { $0.upsert(.remote("notion", url: "https://mcp.notion.com/mcp")) }
        #expect(try text(file) == """
        {
          "mcpServers": {
            "notion": {
              "type": "http",
              "url": "https://mcp.notion.com/mcp"
            }
          }
        }

        """)
    }

    @Test func aFileThatDoesNotParseIsNeverWritten() throws {
        let broken = "{\n  \"mcpServers\": {\n    \"a\": {\"command\" \"x\"}\n  }\n}\n"
        let file = try scratchFile(broken)
        #expect(file.read() == .invalid(line: 3))
        #expect(throws: MCPConfigError.invalid(line: 3)) {
            try file.update { $0.upsert(.local("b", command: "y")) }
        }
        #expect(try text(file) == broken)
        #expect(MCPConfigError.invalid(line: 3).description == "mcp.json isn’t valid JSON (line 3)")
    }

    @Test func aMissingOrEmptyFileHasNoServers() throws {
        #expect(try scratchFile().read() == .document(MCPConfigDocument()))
        #expect(try scratchFile("  \n").read() == .document(MCPConfigDocument()))
    }

    @Test func aNewFileIs0600AndAnExistingFileKeepsItsMode() throws {
        let fresh = try scratchFile()
        try fresh.update { $0.upsert(.local("a", command: "x")) }
        #expect(try mode(fresh.url) == 0o600)

        let shared = try scratchFile("{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: shared.url.path)
        try shared.update { $0.upsert(.local("a", command: "x")) }
        #expect(try mode(shared.url) == 0o644)
        // No temp file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.url.deletingLastPathComponent().path) == ["mcp.json"])
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Someone else saved the file while Shepherd's edit was in flight: the edit is applied again
    /// to what they wrote, so neither change is lost.
    @Test func aFileChangedMidEditIsReadAgainAndTheEditReapplied() throws {
        let file = try scratchFile(#"{"mcpServers": {"a": {"command": "x"}}}"#)
        var attempts = 0
        try file.update { document in
            attempts += 1
            if attempts == 1 {
                try Data(#"{"mcpServers": {"a": {"command": "x"}, "b": {"command": "y"}}}"#.utf8).write(to: file.url)
            }
            document.upsert(.local("c", command: "z"))
        }
        #expect(attempts == 2)
        guard case .document(let document) = file.read() else { Issue.record("unreadable"); return }
        #expect(document.servers.map(\.name) == ["a", "b", "c"])
    }

    @Test func vsCodeServersAreReadAndNewServersGoToMCPServers() throws {
        let file = try scratchFile(#"{"servers": {"gh": {"type": "http", "url": "https://api.githubcopilot.com/mcp/"}}}"#)
        try file.update { $0.upsert(.local("postgres", command: "uvx")) }
        guard case .document(let document) = file.read() else { Issue.record("unreadable"); return }
        #expect(document.servers.map(\.name) == ["gh", "postgres"])
        #expect(document.root["servers"]?["gh"] != nil)
        #expect(document.root["mcpServers"]?["postgres"] != nil)
    }

    @Test(arguments: [
        (#"{"type": "sse", "url": "https://x/sse"}"#, MCPTransportKind.sse, MCPServerEntry.Kind.remote),
        (#"{"type": "http", "url": "https://x/mcp"}"#, .streamableHTTP, .remote),
        (#"{"type": "streamable-http", "url": "https://x/mcp"}"#, .streamableHTTP, .remote),
        (#"{"type": "streamableHttp", "url": "https://x/mcp"}"#, .streamableHTTP, .remote),
        (#"{"url": "https://x/mcp"}"#, .streamableHTTP, .remote),
        (#"{"type": "stdio", "command": "npx"}"#, .stdio, .local),
        (#"{"command": "uvx", "args": ["postgres-mcp"]}"#, .stdio, .local),
    ])
    func entryTypesReadAsTheContractSays(json: String, transport: MCPTransportKind, kind: MCPServerEntry.Kind) throws {
        guard case .success(.object(let object)) = MCPJSON.parse(json) else { Issue.record("bad fixture"); return }
        let entry = MCPServerEntry(name: "x", json: object)
        #expect(entry.transport == transport)
        #expect(entry.kind == kind)
    }

    @Test func shepherdFieldsDefaultWhenMissingAndOnlyChangesAreWritten() {
        var entry = MCPServerEntry.local("grafana", command: "mcp-grafana")
        #expect(entry.settings == MCPShepherdSettings())
        var settings = entry.settings
        settings.exposure = .direct
        settings.tools = ["query", "list_schemas"]
        entry.settings = settings
        #expect(entry.json["shepherd"] == .object(["exposure": .string("direct"),
                                                   "tools": .array([.string("query"), .string("list_schemas")])]))
        settings.exposure = .proxy
        settings.tools = nil
        entry.settings = settings
        // A default the file already named stays named; one it didn't is never added.
        #expect(entry.json["shepherd"] == .object(["exposure": .string("proxy")]))
    }

    @Test func renamingKeepsTheEntryWhole() {
        var document = MCPConfigDocument()
        var entry = MCPServerEntry.remote("old", url: "https://x/mcp")
        entry.json["extra"] = .string("kept")
        document.upsert(entry)
        document.rename("old", to: "new")
        #expect(document.servers.map(\.name) == ["new"])
        #expect(document.server("new")?.json["extra"] == .string("kept"))
    }

    // MARK: Secret references

    @Test(arguments: [
        ("${keychain:grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN}", [("grafana", "GRAFANA_SERVICE_ACCOUNT_TOKEN")]),
        ("Bearer ${keychain:a/Authorization} and ${keychain:b/X}", [("a", "Authorization"), ("b", "X")]),
        ("${GITHUB_TOKEN}", []),
        ("plain", []),
    ])
    func keychainReferencesAreFound(value: String, expected: [(String, String)]) {
        let found = MCPSecretReference.references(in: value)
        #expect(found.map(\.server) == expected.map(\.0))
        #expect(found.map(\.name) == expected.map(\.1))
    }

    @Test(arguments: [
        ("GITHUB_TOKEN", true), ("API_KEY", true), ("CLIENT_SECRET", true), ("DB_PASSWORD", true), ("GITLAB_PAT", true),
        ("DATABASE_URI", true), ("SENTRY_DSN", true), ("Authorization", true),
        ("PATH", false), ("GRAFANA_URL", false), ("HOME", false), ("NODE_ENV", false),
    ])
    func secretLookingKeysAreRecognized(key: String, secret: Bool) {
        #expect(MCPSecretReference.looksSecret(key: key) == secret)
    }

    @Test func theFirstVariableOfAHeaderIsItsSignIn() {
        #expect(MCPSecretReference.variable(in: "Bearer ${GITHUB_TOKEN}") == "GITHUB_TOKEN")
        #expect(MCPSecretReference.variable(in: "${TOKEN:-none}") == "TOKEN")
        #expect(MCPSecretReference.variable(in: "Bearer ${keychain:a/B}") == nil)
    }
}
